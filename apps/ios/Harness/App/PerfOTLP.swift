import Foundation
import UIKit

/// Fixed-cardinality metric names. Resource samples use the same 22 bounds in their normalized source units;
/// the encoder scales the complete histogram (bounds, sum and max), never just its summary values.
enum PerfOTLP {
    static let cpuPercent = "cpu_percent"
    static let footprintMiB = "footprint_mib"
    static let diskWriteKiB = "disk_write_kib"
    static let diskWriteKiBPerSecond = "disk_write_kib_s"
    static let scrollCallbackDelay = "scroll_callback_delay_ms"
    static let streamCallbackDelay = "stream_callback_delay_ms"
    static let resourceMetricOrder = [cpuPercent, footprintMiB, diskWriteKiB, diskWriteKiBPerSecond]
    static let metricOrder = resourceMetricOrder + [scrollCallbackDelay, streamCallbackDelay]
    static let maxResourceSample = 86_400_000.0

    struct Definition {
        let name: String
        let unit: String
        let scale: Double
    }

    static func definition(for metric: String) -> Definition? {
        switch metric {
        case cpuPercent: return Definition(name: "harness.ios.cpu.utilization", unit: "1", scale: 0.01)
        case footprintMiB: return Definition(name: "harness.ios.memory.footprint", unit: "By", scale: 1_048_576)
        case diskWriteKiB: return Definition(name: "harness.ios.disk.write", unit: "By", scale: 1024)
        case diskWriteKiBPerSecond: return Definition(name: "harness.ios.disk.write_rate", unit: "By/s", scale: 1024)
        case scrollCallbackDelay: return Definition(name: "harness.ios.scroll.callback_delay", unit: "ms", scale: 1)
        case streamCallbackDelay: return Definition(name: "harness.ios.stream.callback_delay", unit: "ms", scale: 1)
        default:
            guard PerfMetric.order.contains(metric), metric != "frame_cost_ms", metric.hasSuffix("_ms") else { return nil }
            return Definition(name: "harness.ios.\(metric.dropLast(3))", unit: "ms", scale: 1)
        }
    }
}

/// OTLP/HTTP JSON histogram request. There are no point attributes, exemplars or persistent identities.
struct PerfOTLPBatch {
    let meta: PerfBatchMeta
    let window: PerfWindow

    private static func nanos(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        return ms == 0 ? "0" : "\(ms)000000"
    }

    func json() -> [String: Any] {
        // Reuse the legacy metadata sanitizer without changing its parity-pinned output.
        let sanitized = PerfStatsBatch(meta: meta, window: window).json()
        func string(_ key: String, _ value: String) -> [String: Any] {
            ["key": key, "value": ["stringValue": value]]
        }
        let attributes: [[String: Any]] = [
            string("service.name", "harness.ios"),
            string("service.version", sanitized["app_version"] as? String ?? "0"),
            string("service.instance.id", meta.installId),
            string("os.type", "ios"),
            string("os.version", String(PerfStatsBatch.versionString(meta.osVersion).prefix(16))),
            string("host.arch", meta.arch),
            string("device.model.identifier", sanitized["device"] as? String ?? ""),
            ["key": "display.refresh_rate", "value": ["intValue": String(sanitized["refresh_hz"] as? Int ?? 60)]],
        ]
        let metrics = window.metrics.compactMap { metric -> [String: Any]? in
            guard let definition = PerfOTLP.definition(for: metric.name) else { return nil }
            let point: [String: Any] = [
                "startTimeUnixNano": Self.nanos(window.startMs),
                "timeUnixNano": Self.nanos(max(window.startMs, window.endMs)),
                "count": String(metric.count),
                "sum": metric.sumMs * definition.scale,
                "max": metric.maxMs * definition.scale,
                "explicitBounds": PerfHistograms.bucketsMs.map { $0 * definition.scale },
                "bucketCounts": metric.buckets.map { String($0) },
            ]
            return ["name": definition.name, "unit": definition.unit,
                    "histogram": ["aggregationTemporality": 1, "dataPoints": [point]]]
        }
        return ["resourceMetrics": [[
            "resource": ["attributes": attributes],
            "scopeMetrics": [["scope": ["name": "harness.ios.performance", "version": "1"], "metrics": metrics]],
        ]]]
    }

    func body() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads on one utility queue, retaining only one baseline. State changes synchronously invalidate an in-progress
/// read; no suspended/background, disabled, hot or Low Power interval can become a resource sample.
final class PerfResourceSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "harness.performance.resources", qos: .utility)
    private let lock = NSLock()
    private let source: PerfHistograms
    private let allowed: @Sendable () -> Bool
    private let read: @Sendable () -> PerfResourceSample?
    private var active = false
    private var revision: UInt64 = 0
    private var previous: PerfResourceSample?

    init(source: PerfHistograms, allowed: @escaping @Sendable () -> Bool,
         read: @escaping @Sendable () -> PerfResourceSample? = { PerfResourceSample.read() }) {
        self.source = source
        self.allowed = allowed
        self.read = read
    }

    func setActive(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != active else { return }
        active = value
        previous = nil
        revision &+= 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        previous = nil
        revision &+= 1
    }

    func sample() { queue.async { self.sampleNow() } }

    /// Synchronous entry for deterministic tests; production calls `sample` on the utility queue only.
    func sampleNow() {
        lock.lock()
        let wasActive = active
        let beforeRead = revision
        lock.unlock()
        guard wasActive, allowed() else { reset(); return }
        let generation = source.generation
        guard let current = read() else { reset(); return }
        lock.lock(); defer { lock.unlock() }
        guard active, beforeRead == revision, generation == source.generation, allowed() else {
            previous = nil
            return
        }
        let baseline = previous
        previous = current
        guard let baseline, let interval = current.interval(since: baseline) else { return }
        source.add(PerfOTLP.cpuPercent, ms: interval.cpuPercent, ifGeneration: generation)
        source.add(PerfOTLP.footprintMiB, ms: Double(interval.footprintBytes) / 1_048_576, ifGeneration: generation)
        if let bytes = interval.diskWriteBytes {
            let kib = Double(bytes) / 1024
            source.add(PerfOTLP.diskWriteKiB, ms: kib, ifGeneration: generation)
            source.add(PerfOTLP.diskWriteKiBPerSecond, ms: kib / interval.elapsedSeconds, ifGeneration: generation)
        }
    }
}

/// Main-thread lifecycle only; counters themselves are read off-main. Local operation timings remain available
/// with sharing off; resource diagnostics are sampled only in physical-device release builds with sharing on.
@MainActor
final class PerfResourceRuntime {
    static let shared = PerfResourceRuntime()
    private let source = Perf.shared.histograms
    private let sampler = PerfResourceSampler(source: Perf.shared.histograms, allowed: {
        PerfSharing.collectingEnabled && PerfPolicy.deviceIsCalm(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: Perf.thermalLabel)
    })
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var foreground = false
    private var consent = PerfSharing.enabled
    private var lastFlushAt = ProcessInfo.processInfo.systemUptime

    func start() {
        guard observers.isEmpty else { return }
        foreground = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.foreground = true; self.reconcile() }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.foreground = false; self.reconcile() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.foreground = false; self.reconcile() }
            },
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.reconcile() }
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.reconcile() }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.reconcile() }
            },
        ]
        reconcile()
    }

    func consentChanged() {
        source.discard()
        sampler.reset()
        consent = PerfSharing.enabled
        reconcile()
    }

    private func reconcile() {
        if consent != PerfSharing.enabled { consentChanged(); return }
        if !PerfSharing.collectingEnabled { source.discard() }
        let calm = PerfPolicy.deviceIsCalm(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: Perf.thermalLabel)
        let active = foreground && PerfSharing.collectingEnabled && calm
        sampler.setActive(active)
        if active, timer == nil {
            sampler.sample() // Establish a fresh baseline without waiting for the first interval.
            let next = Timer(timeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            next.tolerance = 1
            timer = next
            RunLoop.main.add(next, forMode: .common)
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        reconcile()
        guard foreground else { return }
        sampler.sample()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFlushAt >= Double(PerfUploader.minIntervalMs) / 1000 {
            lastFlushAt = now
            PerfSharing.flush()
        }
    }
}
