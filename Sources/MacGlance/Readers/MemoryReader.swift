import Darwin

/// How hard macOS has to work to find free memory. This, not the Used number, says if RAM is short.
enum MemoryPressure: Int32 {
    case normal = 1     // green: plenty
    case warning = 2    // yellow: compressing and swapping a lot
    case critical = 4   // red: may start closing apps
}

struct MemoryUsage {
    let total: UInt64        // physical RAM, bytes
    let app: UInt64          // what apps hold, minus what they marked as safe to throw away
    let wired: UInt64        // kernel memory that can never be moved out of RAM
    let compressed: UInt64   // pages squeezed by the memory compressor
    let swap: UInt64         // pushed out to the SSD
    let pressure: MemoryPressure

    /// Same "Memory Used" as Activity Monitor. File cache is left out: macOS frees it on demand.
    var used: UInt64 { app + wired + compressed }
    var usedPercent: Double { Double(used) / Double(total) * 100 }
}

/// RAM usage from the kernel's page counters.
final class MemoryReader {
    private let host = mach_host_self()
    private let pageSize = UInt64(vm_kernel_page_size)   // 16 KB on Apple Silicon
    private let total: UInt64 = {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        return bytes
    }()

    func read() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        let appPages = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        return MemoryUsage(total: total,
                           app: appPages * pageSize,
                           wired: UInt64(stats.wire_count) * pageSize,
                           compressed: UInt64(stats.compressor_page_count) * pageSize,
                           swap: swap.xsu_used,
                           pressure: Self.pressure())
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: level) ?? .normal
    }
}
