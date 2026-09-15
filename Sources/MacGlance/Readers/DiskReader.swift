import Foundation
import IOKit

struct DiskUsage {
    let total: UInt64              // bytes on the startup disk
    let free: UInt64               // same "Available" as Finder, incl. space macOS can clear on its own
    let readPerSecond: Double?     // bytes/s over all real disks, nil until there are two samples
    let writePerSecond: Double?
}

/// Free space on the startup disk, and how fast the real disks read and write.
final class DiskReader {
    private var previous: (read: UInt64, write: UInt64, time: Date)?
    private var space: (total: UInt64, free: UInt64, time: Date)?

    func read() -> DiskUsage? {
        guard let space = freeSpace() else { return nil }
        let speed = throughput()
        return DiskUsage(total: space.total, free: space.free, readPerSecond: speed?.read, writePerSecond: speed?.write)
    }

    /// Free space changes slowly and costs the most to ask for, so it is cached for 30 s.
    private func freeSpace() -> (total: UInt64, free: UInt64)? {
        if let space, Date().timeIntervalSince(space.time) < 30 { return (space.total, space.free) }
        let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity,
              let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        space = (UInt64(total), UInt64(free), Date())
        return (UInt64(total), UInt64(free))
    }

    /// Bytes read/written since boot by every disk driver, turned into a speed between two calls.
    private func throughput() -> (read: Double, write: Double)? {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        // Looked up every time, so a disk plugged in later is counted too.
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            if isRealDisk(driver),
               let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                   .takeRetainedValue() as? NSDictionary {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(driver)
            driver = IOIteratorNext(iterator)
        }

        let now = Date()
        defer { previous = (read, write, now) }
        guard let previous else { return nil }
        let seconds = now.timeIntervalSince(previous.time)
        // A stale baseline (not read for a while) or an unplugged disk: wait for the next sample.
        guard seconds > 0, seconds < 10, read >= previous.read, write >= previous.write else { return nil }
        return (Double(read - previous.read) / seconds, Double(write - previous.write) / seconds)
    }

    /// Mounted .dmg files are skipped: their reads and writes already land on a real disk.
    private func isRealDisk(_ driver: io_registry_entry_t) -> Bool {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(device) }
        let protocolInfo = IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSDictionary
        return protocolInfo?["Physical Interconnect"] as? String != "Virtual Interface"
    }
}
