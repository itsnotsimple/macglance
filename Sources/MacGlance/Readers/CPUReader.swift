import Darwin
import Foundation
import IOKit

enum CoreKind {
    case performance   // P-cores: fast, power hungry
    case efficiency    // E-cores: slower, sip power
}

struct CPULoad {
    let total: Double     // 0...100, all cores together
    let cores: [Double]   // 0...100 for each core, in the kernel's order
}

/// CPU load from the kernel's per-core tick counters.
/// The counters only ever grow, so load = busy ticks / all ticks between two reads.
final class CPUReader {
    /// P or E for every core, read once. Empty if the Mac doesn't say (then cores aren't grouped).
    static let coreKinds: [CoreKind] = readCoreKinds()

    private let host = mach_host_self()
    private var previous: [UInt32] = []   // CPU_STATE_MAX counters per core, all cores in a row

    /// Load over the time since the previous call. Nil on the first call (no baseline yet).
    func read() -> CPULoad? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let current = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        var cores: [Double] = []
        for core in 0..<Int(coreCount) {
            let base = core * Int(CPU_STATE_MAX)
            var coreBusy: UInt64 = 0
            var coreTotal: UInt64 = 0
            for state in 0..<Int(CPU_STATE_MAX) {
                let delta = UInt64(current[base + state] &- previous[base + state])   // &- survives counter wrap
                coreTotal += delta
                if state != Int(CPU_STATE_IDLE) { coreBusy += delta }
            }
            cores.append(coreTotal == 0 ? 0 : Double(coreBusy) / Double(coreTotal) * 100)
            busy += coreBusy
            total += coreTotal
        }
        return CPULoad(total: total == 0 ? 0 : Double(busy) / Double(total) * 100, cores: cores)
    }

    /// The device tree has one entry per core, with its number and cluster type ("E" or "P").
    private static func readCoreKinds() -> [CoreKind] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var kinds: [Int: CoreKind] = [:]
        var cpu = IOIteratorNext(iterator)
        while cpu != 0 {
            let id = IORegistryEntryCreateCFProperty(cpu, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            let type = IORegistryEntryCreateCFProperty(cpu, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
            if let id, let type {
                kinds[id.intValue] = type.first == UInt8(ascii: "P") ? .performance : .efficiency
            }
            IOObjectRelease(cpu)
            cpu = IOIteratorNext(iterator)
        }
        let ordered = (0..<kinds.count).compactMap { kinds[$0] }
        return ordered.count == kinds.count ? ordered : []   // gaps in the numbering: don't guess
    }
}
