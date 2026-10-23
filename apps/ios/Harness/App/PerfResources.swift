import Darwin
import Foundation

/// Own-process counters. `at` is a local monotonic clock used only for interval math, never upload it.
struct PerfResourceSample {
    let at: Double
    let cpuSeconds: Double
    let footprintBytes: UInt64
    /// Physical disk writes reported by the OS, not logical filesystem writes. Nil means unavailable.
    let diskWriteBytes: UInt64?

    /// A fixed number of own-process queries; no thread enumeration, process scans or retained history.
    static func read() -> PerfResourceSample? {
        let at = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, at.isFinite, cpuSeconds.isFinite else { return nil }

        var diskWriteBytes: UInt64 = 0
        let hasDiskWrites = HarnessReadDiskWriteBytes(&diskWriteBytes) != 0
        return PerfResourceSample(at: at, cpuSeconds: cpuSeconds, footprintBytes: info.phys_footprint,
                                  diskWriteBytes: hasDiskWrites ? diskWriteBytes : nil)
    }

    /// Drop discontinuities and suspension gaps rather than attributing them to an active interval.
    func interval(since previous: PerfResourceSample) -> PerfResourceInterval? {
        guard at.isFinite, previous.at.isFinite, at >= 0, previous.at >= 0,
              cpuSeconds.isFinite, previous.cpuSeconds.isFinite,
              previous.cpuSeconds >= 0, cpuSeconds >= previous.cpuSeconds else { return nil }
        let elapsed = at - previous.at
        guard elapsed.isFinite, elapsed > 0, elapsed <= 15 else { return nil }
        let cpuPercent = (cpuSeconds - previous.cpuSeconds) / elapsed * 100
        guard cpuPercent.isFinite else { return nil }

        let diskDelta: UInt64?
        if let current = diskWriteBytes, let previous = previous.diskWriteBytes {
            guard current >= previous else { return nil }
            diskDelta = current - previous
        } else {
            diskDelta = nil
        }
        return PerfResourceInterval(cpuPercent: cpuPercent, footprintBytes: footprintBytes,
                                    diskWriteBytes: diskDelta, elapsedSeconds: elapsed)
    }
}

/// Exportable resource values: no absolute clock, process identifiers or lifetime counters.
struct PerfResourceInterval {
    /// 100% is one fully occupied core; a multicore process can legitimately exceed 100%.
    let cpuPercent: Double
    let footprintBytes: UInt64
    let diskWriteBytes: UInt64?
    let elapsedSeconds: Double
}
