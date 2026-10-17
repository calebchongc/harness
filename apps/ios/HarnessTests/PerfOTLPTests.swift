import XCTest
@testable import Harness

final class PerfOTLPTests: XCTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private actor ResponseGate {
        private var continuation: CheckedContinuation<Int, Never>?
        private var result: Int?
        func response() async -> Int {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ status: Int) {
            result = status
            continuation?.resume(returning: status)
            continuation = nil
        }
    }

    private var meta: PerfBatchMeta {
        PerfBatchMeta(installId: "11111111-2222-4333-8444-555555555555", os: "ios", arch: "aarch64",
                      appVersion: "1.4 (212)", osVersion: "27.0 (test)", device: "iPhone18,1™<>/", refreshHz: 500)
    }

    private func resource(_ json: [String: Any]) throws -> [String: Any] {
        let resources = try XCTUnwrap(json["resourceMetrics"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 1)
        return try XCTUnwrap(resources.first)
    }

    private func metrics(_ json: [String: Any]) throws -> [[String: Any]] {
        let scopes = try XCTUnwrap(try resource(json)["scopeMetrics"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0]["scope"] as? [String: String], ["name": "harness.ios.performance", "version": "1"])
        return try XCTUnwrap(scopes[0]["metrics"] as? [[String: Any]])
    }

    func testOTLPWireScalesEveryHistogramFieldAndUsesOnlyApprovedResourceAttributes() throws {
        let clock = Locked(1_790_000_000_000)
        let source = PerfHistograms(now: { clock.value })
        let names = [PerfMetric.appLaunch] + PerfOTLP.metricOrder
        for name in names { source.add(name, ms: 2); source.add(name, ms: 3) }
        clock.value += 600_000
        let window = try XCTUnwrap(source.take())
        let body = PerfOTLPBatch(meta: meta, window: window).body()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["resourceMetrics"])
        let r = try resource(json)
        let resourceObject = try XCTUnwrap(r["resource"] as? [String: Any])
        let attributes = try XCTUnwrap(resourceObject["attributes"] as? [[String: Any]])
        XCTAssertEqual(attributes.count, 8)
        let keyed = Dictionary(uniqueKeysWithValues: try attributes.map {
            (try XCTUnwrap($0["key"] as? String), try XCTUnwrap($0["value"] as? [String: String]))
        })
        XCTAssertEqual(keyed, [
            "service.name": ["stringValue": "harness.ios"],
            "service.version": ["stringValue": "1.4--212-"],
            "service.instance.id": ["stringValue": meta.installId],
            "os.type": ["stringValue": "ios"],
            "os.version": ["stringValue": "27.0--test-"],
            "host.arch": ["stringValue": "aarch64"],
            "device.model.identifier": ["stringValue": "iPhone18,1"],
            "display.refresh_rate": ["intValue": "240"],
        ])
        let encoded = try metrics(json)
        let expectedNames = ["harness.ios.app_launch", "harness.ios.cpu.utilization", "harness.ios.memory.footprint",
                             "harness.ios.disk.write", "harness.ios.disk.write_rate", "harness.ios.scroll.callback_delay",
                             "harness.ios.stream.callback_delay"]
        XCTAssertEqual(encoded.compactMap { $0["name"] as? String }, expectedNames)
        let scales: [Double] = [1, 0.01, 1_048_576, 1024, 1024, 1, 1]
        let units = ["ms", "1", "By", "By", "By/s", "ms", "ms"]
        for (index, metric) in encoded.enumerated() {
            XCTAssertEqual(Set(metric.keys), ["name", "unit", "histogram"])
            XCTAssertEqual(metric["unit"] as? String, units[index])
            let histogram = try XCTUnwrap(metric["histogram"] as? [String: Any])
            XCTAssertEqual(histogram["aggregationTemporality"] as? Int, 1)
            let points = try XCTUnwrap(histogram["dataPoints"] as? [[String: Any]])
            XCTAssertEqual(points.count, 1)
            let point = points[0]
            XCTAssertEqual(Set(point.keys), ["startTimeUnixNano", "timeUnixNano", "count", "sum", "max", "explicitBounds", "bucketCounts"])
            XCTAssertEqual(point["startTimeUnixNano"] as? String, "1790000000000000000")
            XCTAssertEqual(point["timeUnixNano"] as? String, "1790000600000000000")
            XCTAssertEqual(point["count"] as? String, "2")
            XCTAssertEqual(point["sum"] as? Double, 5 * scales[index])
            XCTAssertEqual(point["max"] as? Double, 3 * scales[index])
            XCTAssertEqual(point["explicitBounds"] as? [Double], PerfHistograms.bucketsMs.map { $0 * scales[index] })
            var counts = [String](repeating: "0", count: 23)
            counts[1] = "1"; counts[2] = "1"
            XCTAssertEqual(point["bucketCounts"] as? [String], counts)
        }
    }

    func testLegacyNamesKeepTheirMappingAndResourcesDoNotUseTheLegacyClamp() throws {
        let source = PerfHistograms(now: { 10 })
        for name in PerfMetric.order + PerfOTLP.metricOrder { source.add(name, ms: 90_000_000) }
        source.add("arbitrary_identity", ms: 1)
        source.add(PerfOTLP.cpuPercent, ms: .nan)
        source.add(PerfOTLP.cpuPercent, ms: .infinity)
        let window = try XCTUnwrap(source.take())
        XCTAssertEqual(window.metrics.map(\.name), PerfMetric.order + PerfOTLP.metricOrder)
        for metric in window.metrics {
            let resource = PerfOTLP.resourceMetricOrder.contains(metric.name)
            XCTAssertEqual(metric.maxMs, resource ? 86_400_000 : 60_000)
            XCTAssertEqual(metric.buckets[resource ? 22 : 21], 1)
        }
        let encoded = try metrics(PerfOTLPBatch(meta: meta, window: window).json())
        let iosTimings = PerfMetric.order.filter { $0 != "frame_cost_ms" }
        XCTAssertEqual(encoded.prefix(iosTimings.count).compactMap { $0["name"] as? String },
                       iosTimings.map { "harness.ios.\($0.dropLast(3))" })
        XCTAssertNil(PerfOTLP.definition(for: "frame_cost_ms"), "Android render cost is not an iOS instrument")
    }

    func testUploaderInjectsOTLPButDefaultsToLegacyEncoding() async throws {
        let seen = Locked<[String]>([])
        for otlp in [false, true] {
            let source = PerfHistograms(now: { 1 })
            source.add(PerfMetric.mainTurn, ms: 2)
            let uploader: PerfUploader
            if otlp {
                uploader = PerfUploader(endpoint: "https://example.invalid/v1/metrics", enabled: { true }, source: source,
                                        body: { PerfOTLPBatch(meta: $0, window: $1).body() },
                                        post: { _, body in seen.value.append(body); return 204 })
            } else {
                uploader = PerfUploader(endpoint: "https://example.invalid/perf", enabled: { true }, source: source,
                                        post: { _, body in seen.value.append(body); return 204 })
            }
            let sent = await uploader.flush(meta: meta)
            XCTAssertTrue(sent)
        }
        let bodies = try seen.value.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(bodies[0]["schema"] as? String, PerfStatsBatch.schema)
        XCTAssertNotNil(bodies[1]["resourceMetrics"])
        XCTAssertNil(bodies[1]["schema"])
    }

    func testReentrantFlushDoesNotSendASecondWindowAndRevocationDoesNotRestoreTheFirst() async {
        let source = PerfHistograms(now: { 1 })
        let enabled = Locked(true)
        let gate = ResponseGate()
        let started = expectation(description: "request waiting")
        let uploader = PerfUploader(endpoint: "https://example.invalid/v1/metrics", enabled: { enabled.value }, source: source,
                                    post: { _, _ in started.fulfill(); return await gate.response() })
        source.add(PerfMetric.mainTurn, ms: 1)
        let metadata = meta
        let first = Task { await uploader.flush(meta: metadata) }
        await fulfillment(of: [started], timeout: 2)
        source.add(PerfMetric.mainTurn, ms: 2)
        let second = await uploader.flush(meta: metadata)
        XCTAssertFalse(second)
        XCTAssertEqual(source.pendingSamples, 1, "a reentrant call must not consume another window")
        enabled.value = false
        await gate.finish(503)
        let sent = await first.value
        XCTAssertFalse(sent)
        XCTAssertEqual(source.pendingSamples, 0, "neither the in-flight nor disabled window may survive revocation")
    }

    func testRevokedWindowStaysInvalidEvenIfConsentReturnsBeforeTheResponse() async {
        let source = PerfHistograms(now: { 1 })
        let gate = ResponseGate()
        let started = expectation(description: "request waiting")
        let uploader = PerfUploader(endpoint: "https://example.invalid/v1/metrics", enabled: { true }, source: source,
                                    post: { _, _ in started.fulfill(); return await gate.response() })
        source.add(PerfMetric.mainTurn, ms: 1)
        let metadata = meta
        let first = Task { await uploader.flush(meta: metadata) }
        await fulfillment(of: [started], timeout: 2)
        source.discard() // The synchronous consent-change hook, including off -> on while the request is suspended.
        source.add(PerfMetric.mainTurn, ms: 7)
        await gate.finish(503)
        let sent = await first.value
        XCTAssertFalse(sent)
        XCTAssertEqual(source.pendingSamples, 1, "only the newly consented window may remain")
    }

    func testRetryBackoffMatchesLegacyPolicyAndDisabledSamplesAreDroppedDuringBackoff() async {
        let clock = Locked(0), status = Locked(503), enabled = Locked(true)
        let posts = Locked(0)
        let source = PerfHistograms(now: { clock.value })
        let uploader = PerfUploader(endpoint: "https://example.invalid/v1/metrics", enabled: { enabled.value }, source: source,
                                    now: { clock.value }, post: { _, _ in posts.value += 1; return status.value })
        source.add(PerfMetric.mainTurn, ms: 1)
        let failed = await uploader.flush(meta: meta)
        XCTAssertFalse(failed)
        clock.value = 1; status.value = 429
        let limited = await uploader.flush(meta: meta)
        XCTAssertFalse(limited)
        XCTAssertEqual(posts.value, 2, "5xx starts no wait")
        clock.value = 2; status.value = 204
        let backedOff = await uploader.flush(meta: meta)
        XCTAssertFalse(backedOff)
        XCTAssertEqual(posts.value, 2, "429 starts the minimum interval")
        enabled.value = false
        let disabled = await uploader.flush(meta: meta)
        XCTAssertFalse(disabled)
        XCTAssertEqual(source.pendingSamples, 0)
        enabled.value = true
        source.add(PerfMetric.mainTurn, ms: 3)
        clock.value = 600_001
        let sent = await uploader.flush(meta: meta)
        XCTAssertTrue(sent)
        XCTAssertEqual(posts.value, 3)
    }

    func testSamplerGatesReadsResetsBaselinesAndExportsOnlyIntervalValues() throws {
        let source = PerfHistograms(now: { 1 })
        let allowed = Locked(false), reads = Locked(0)
        let sample = Locked<PerfResourceSample?>(PerfResourceSample(at: 10, cpuSeconds: 3, footprintBytes: 2_097_152, diskWriteBytes: 1024))
        let sampler = PerfResourceSampler(source: source, allowed: { allowed.value }, read: {
            reads.value += 1
            return sample.value
        })
        sampler.setActive(true)
        sampler.sampleNow()
        XCTAssertEqual(reads.value, 0, "no process queries before consent")
        allowed.value = true
        sampler.sampleNow()
        sample.value = PerfResourceSample(at: 15, cpuSeconds: 5.5, footprintBytes: 3_145_728, diskWriteBytes: 11_264)
        sampler.sampleNow()
        let window = try XCTUnwrap(source.take())
        XCTAssertEqual(window.metrics.map(\.name), PerfOTLP.resourceMetricOrder)
        XCTAssertEqual(window.metrics.map(\.sumMs), [50, 3, 10, 2])
        sampler.setActive(false)
        sampler.sampleNow()
        XCTAssertEqual(reads.value, 2, "backgrounded sampler must not query the process")
        sampler.setActive(true)
        sample.value = PerfResourceSample(at: 20, cpuSeconds: 100, footprintBytes: 1, diskWriteBytes: 20_000)
        sampler.sampleNow()
        XCTAssertEqual(source.pendingSamples, 0, "resuming must establish a new baseline")
        allowed.value = false // Consent, low-power and hot policy all enter the same gated path.
        sampler.sampleNow()
        XCTAssertEqual(reads.value, 3)
        allowed.value = true
        sample.value = PerfResourceSample(at: 25, cpuSeconds: 101, footprintBytes: 1, diskWriteBytes: nil)
        sampler.sampleNow()
        XCTAssertEqual(source.pendingSamples, 0, "a policy hold also resets the baseline")
        sample.value = PerfResourceSample(at: 30, cpuSeconds: 102, footprintBytes: 1_048_576, diskWriteBytes: nil)
        sampler.sampleNow()
        XCTAssertEqual(try XCTUnwrap(source.take()).metrics.map(\.name), [PerfOTLP.cpuPercent, PerfOTLP.footprintMiB])
        sample.value = nil
        sampler.sampleNow()
        XCTAssertEqual(source.pendingSamples, 0, "a failed process read must not become a zero sample")
        sample.value = PerfResourceSample(at: 35, cpuSeconds: 103, footprintBytes: 1_048_576, diskWriteBytes: nil)
        sampler.sampleNow()
        XCTAssertEqual(source.pendingSamples, 0, "a failed read must reset the baseline before recovery")
    }

    func testExpandedDiagnosticsRequireNewConsentInsteadOfTimingOnlyConsent() {
        let defaults = UserDefaults.standard
        let oldKey = "share-performance-consent-v1"
        let savedOld = defaults.object(forKey: oldKey), savedNew = defaults.object(forKey: PerfSharing.key)
        defer {
            if let savedOld { defaults.set(savedOld, forKey: oldKey) } else { defaults.removeObject(forKey: oldKey) }
            if let savedNew { defaults.set(savedNew, forKey: PerfSharing.key) } else { defaults.removeObject(forKey: PerfSharing.key) }
        }
        defaults.set(true, forKey: oldKey)
        defaults.removeObject(forKey: PerfSharing.key)
        XCTAssertEqual(PerfSharing.key, "share-performance-consent-v2")
        XCTAssertFalse(PerfSharing.enabled)
        XCTAssertEqual(PerfSharing.otlpEndpoint, "https://otel.codegraff.com/v1/metrics")
    }
}
