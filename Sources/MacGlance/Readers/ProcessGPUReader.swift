import AppKit
import IOKit

struct ProcessGPU: Identifiable {
    let id: pid_t                     // the owner: the app, or the process itself
    let name: String
    let app: NSRunningApplication?    // nil for background processes
    let percent: Double               // share of the GPU's time, like Activity Monitor's GPU column

    var canQuit: Bool { app.map(isQuittable) ?? false }
}

/// Who is using the GPU. The driver keeps one client entry per process that talks to it,
/// with the GPU time it has used so far (ns). Unlike CPU time, this is readable for every
/// process, system ones like WindowServer included.
final class ProcessGPUReader {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private let nanosPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Empty on the first call: GPU % needs two samples. About 0.6 ms per call.
    func top(_ count: Int) -> [ProcessGPU] {
        let now = mach_absolute_time()
        let (current, names) = Self.gpuTimeByProcess()
        var nanosByOwner: [pid_t: UInt64] = [:]
        for (pid, time) in current {
            if let before = previous[pid], time >= before {
                nanosByOwner[Processes.owner(of: pid), default: 0] += time - before
            }
        }
        let elapsed = Double(now - previousTime) * nanosPerTick
        let hadBaseline = previousTime != 0
        previous = current
        previousTime = now
        guard hadBaseline, elapsed > 0 else { return [] }

        return nanosByOwner
            .map { owner, nanos in (owner, Double(nanos) / elapsed * 100) }
            .filter { $0.1 >= 0.1 }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { owner, percent in
                let app = NSRunningApplication(processIdentifier: owner)
                let name = app?.localizedName ?? names[owner] ?? Processes.name(owner)
                return ProcessGPU(id: owner, name: name, app: app, percent: percent)
            }
    }

    /// GPU time so far (ns) per pid, plus the name the driver recorded for each ("pid 407, WindowServer").
    static func gpuTimeByProcess() -> ([pid_t: UInt64], [pid_t: String]) {
        var times: [pid_t: UInt64] = [:]
        var names: [pid_t: String] = [:]
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accelerator != 0 else { return (times, names) }
        defer { IOObjectRelease(accelerator) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return (times, names) }
        defer { IOObjectRelease(iterator) }

        var client = IOIteratorNext(iterator)
        while client != 0 {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(client, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = unmanaged?.takeRetainedValue() as? [String: Any],
               let creator = properties["IOUserClientCreator"] as? String,   // "pid 407, WindowServer"
               let usage = properties["AppUsage"] as? [[String: Any]] {
                let parts = creator.dropFirst("pid ".count).split(separator: ",", maxSplits: 1)
                if let pid = pid_t(parts.first ?? "") {
                    let nanos = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
                    times[pid, default: 0] += nanos   // a process can hold several clients
                    if parts.count > 1 { names[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
            }
            IOObjectRelease(client)
            client = IOIteratorNext(iterator)
        }
        return (times, names)
    }
}
