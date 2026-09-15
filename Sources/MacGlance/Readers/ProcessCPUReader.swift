import AppKit

struct ProcessCPU: Identifiable {
    let id: pid_t                     // the owner: the app, or the process itself
    let name: String
    let app: NSRunningApplication?    // nil for background processes
    let percent: Double               // like Activity Monitor: 100 = one core fully busy

    var canQuit: Bool { app.map(isQuittable) ?? false }
}

/// Who is using the CPU right now, per app (helpers count toward their app), else per process.
/// Processes that run as root (kernel_task, WindowServer) can't be read without admin rights.
final class ProcessCPUReader {
    private var previous: [pid_t: UInt64] = [:]   // CPU time so far per process, in mach time units
    private var previousTime: UInt64 = 0
    private let nanosPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)   // Apple Silicon counts in 1/24 µs, not nanoseconds
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Empty on the first call: CPU % needs two samples.
    func top(_ count: Int) -> [ProcessCPU] {
        let now = mach_absolute_time()
        var current: [pid_t: UInt64] = [:]
        var ticksByOwner: [pid_t: UInt64] = [:]
        for pid in Processes.all() {
            guard let usage = Processes.usage(pid) else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            current[pid] = cpuTime
            if let before = previous[pid], cpuTime >= before {   // new processes count from the next sample
                ticksByOwner[Processes.owner(of: pid), default: 0] += cpuTime - before
            }
        }
        let elapsed = Double(now - previousTime) * nanosPerTick
        let hadBaseline = previousTime != 0
        previous = current
        previousTime = now
        guard hadBaseline, elapsed > 0 else { return [] }

        return ticksByOwner
            .map { owner, ticks in (owner, Double(ticks) * nanosPerTick / elapsed * 100) }
            .filter { $0.1 >= 0.1 }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { owner, percent in
                let app = NSRunningApplication(processIdentifier: owner)
                return ProcessCPU(id: owner, name: app?.localizedName ?? Processes.name(owner), app: app, percent: percent)
            }
    }
}
