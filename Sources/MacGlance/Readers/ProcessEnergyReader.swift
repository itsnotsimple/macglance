import AppKit

struct AppEnergy: Identifiable {
    let id: pid_t                     // the owner: the app, or the process itself
    let name: String
    let app: NSRunningApplication?    // nil for background processes
    let cpuWatts: Double              // measured by the kernel
    let gpuWatts: Double              // GPU watts × this app's share of GPU time

    var watts: Double { cpuWatts + gpuWatts }
    var canQuit: Bool { app.map(isQuittable) ?? false }
}

/// Watts per app. The kernel keeps the CPU energy every process has used (ri_energy_nj),
/// so the CPU part is a real measurement. The GPU has no per-app energy counter, so its
/// watts are split by each app's share of GPU time. Helpers count toward their app.
final class ProcessEnergyReader {
    private var previous: [pid_t: UInt64] = [:]   // CPU energy so far per process, nJ
    private var previousTime = Date()
    private let gpuShares = ProcessGPUReader()

    /// Empty on the first call, or when the last call was too long ago to be a fair baseline
    /// (e.g. the menu was closed for a while). `gpuWatts` is the GPU's total right now.
    func top(_ count: Int, gpuWatts: Double) -> [AppEnergy] {
        let now = Date()
        var current: [pid_t: UInt64] = [:]
        var joulesByOwner: [pid_t: Double] = [:]
        for pid in Processes.all() {
            guard let usage = Processes.usage(pid) else { continue }   // root processes need admin rights
            current[pid] = usage.ri_energy_nj
            if let before = previous[pid], usage.ri_energy_nj >= before {
                joulesByOwner[Processes.owner(of: pid), default: 0] += Double(usage.ri_energy_nj - before) / 1e9
            }
        }
        let seconds = now.timeIntervalSince(previousTime)
        let hadBaseline = !previous.isEmpty
        previous = current
        previousTime = now

        let gpu = gpuShares.top(50)   // GPU time share per owner, in %
        guard hadBaseline, seconds > 0, seconds < 10 else { return [] }

        var owners = Set(joulesByOwner.keys)
        owners.formUnion(gpu.map(\.id))
        return owners
            .map { owner in
                let gpuPart = gpu.first { $0.id == owner }.map { $0.percent / 100 * gpuWatts } ?? 0
                let app = NSRunningApplication(processIdentifier: owner)
                let name = app?.localizedName ?? gpu.first { $0.id == owner }?.name ?? Processes.name(owner)
                return AppEnergy(id: owner, name: name, app: app,
                                 cpuWatts: (joulesByOwner[owner] ?? 0) / seconds, gpuWatts: gpuPart)
            }
            .filter { $0.watts >= 0.01 }
            .sorted { $0.watts > $1.watts }
            .prefix(count)
            .map { $0 }
    }
}
