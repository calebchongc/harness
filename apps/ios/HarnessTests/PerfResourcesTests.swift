import XCTest
@testable import Harness

final class PerfResourcesTests: XCTestCase {
    private func sample(at: Double = 10, cpu: Double = 2, memory: UInt64 = 1_024,
                        disk: UInt64? = 100) -> PerfResourceSample {
        PerfResourceSample(at: at, cpuSeconds: cpu, footprintBytes: memory, diskWriteBytes: disk)
    }

    func testIntervalUsesCounterDeltasAndLatestFootprint() throws {
        let interval = try XCTUnwrap(sample(at: 12, cpu: 2.5, memory: 512, disk: 356)
            .interval(since: sample()))
        XCTAssertEqual(interval.elapsedSeconds, 2)
        XCTAssertEqual(interval.cpuPercent, 25, accuracy: 0.000_001)
        XCTAssertEqual(interval.footprintBytes, 512, "a declining memory gauge is not a counter reset")
        XCTAssertEqual(interval.diskWriteBytes, 256)
    }

    func testMulticoreCPUIsNotClampedOrDividedByCoreCount() throws {
        let interval = try XCTUnwrap(sample(at: 12, cpu: 7).interval(since: sample()))
        XCTAssertEqual(interval.cpuPercent, 250, accuracy: 0.000_001)
    }

    func testIdleCountersReallyProduceZero() throws {
        let interval = try XCTUnwrap(sample(at: 11).interval(since: sample()))
        XCTAssertEqual(interval.cpuPercent, 0)
        XCTAssertEqual(interval.diskWriteBytes, 0)
    }

    func testMissingDiskDataIsNotFabricatedAsZero() throws {
        let counters: [(UInt64?, UInt64?)] = [(nil, nil), (nil, 200), (100, nil)]
        for (before, after) in counters {
            let previous = sample(disk: before)
            let current = sample(at: 11, cpu: 2.5, disk: after)
            let interval = try XCTUnwrap(current.interval(since: previous))
            XCTAssertEqual(interval.cpuPercent, 50)
            XCTAssertNil(interval.diskWriteBytes)
        }
    }

    func testCounterResetsAreRejected() {
        XCTAssertNil(sample(at: 11, cpu: 1).interval(since: sample()))
        XCTAssertNil(sample(at: 11, disk: 99).interval(since: sample()))
        XCTAssertNil(sample(at: 11, cpu: -1).interval(since: sample(cpu: -2)))
    }

    func testClockReversalsZeroElapsedAndSuspensionGapsAreRejected() {
        for at in [9.0, 10, 25.001, 300] {
            XCTAssertNil(sample(at: at).interval(since: sample()), "timestamp \(at) must be rejected")
        }
        XCTAssertNotNil(sample(at: 25).interval(since: sample()), "15 seconds is an accepted boundary")
        XCTAssertNil(sample(at: 1).interval(since: sample(at: -1)))
    }

    func testNonfiniteClockOrCPUIsRejectedOnEitherSide() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(sample(at: value).interval(since: sample()))
            XCTAssertNil(sample(at: 11).interval(since: sample(at: value)))
            XCTAssertNil(sample(at: 11, cpu: value).interval(since: sample()))
            XCTAssertNil(sample(at: 11).interval(since: sample(cpu: value)))
        }
    }

    func testOverflowingCPURateIsRejected() {
        XCTAssertNil(sample(at: 11, cpu: .greatestFiniteMagnitude)
            .interval(since: sample(cpu: 0)))
    }

    func testDiskDeltaKeepsUInt64Precision() throws {
        let interval = try XCTUnwrap(sample(at: 11, disk: UInt64.max)
            .interval(since: sample(disk: UInt64.max - 3)))
        XCTAssertEqual(interval.diskWriteBytes, 3)
    }

    func testReadingOwnProcessProducesFiniteCPUAndPhysicalFootprint() throws {
        let reading = try XCTUnwrap(PerfResourceSample.read())
        XCTAssertTrue(reading.at.isFinite)
        XCTAssertGreaterThanOrEqual(reading.at, 0)
        XCTAssertTrue(reading.cpuSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(reading.cpuSeconds, 0)
        XCTAssertGreaterThan(reading.footprintBytes, 0)
        // Disk access can be unavailable in a sandbox; nil must remain a valid reading.
    }
}
