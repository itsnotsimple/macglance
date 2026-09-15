import AppKit

/// Energy kept on disk: what the Mac used, what it drew from the wall (that's what the
/// electricity bill counts), and how much each app used. Per day for the bill, plus finer
/// buckets for "who used what" over any chart period: per minute for the last 2 hours,
/// per hour for the last 7 days.
final class EnergyLedger {
    static let shared = EnergyLedger()

    struct Day: Codable {
        var usedWh = 0.0                     // the whole Mac, from SMC system power
        var wallWh = 0.0                     // from the charger: running + charging the battery
        var apps: [String: AppDay] = [:]     // key: bundle id, or the process name
    }

    struct AppDay: Codable {
        var name: String
        var wh: Double
    }

    /// One minute or one hour of energy.
    struct Bucket: Codable {
        var start: TimeInterval   // seconds since 1970
        var usedWh = 0.0
        var wallWh = 0.0
        var apps: [String: AppDay] = [:]
    }

    struct Usage {
        let usedWh: Double
        let wallWh: Double
        let apps: [(key: String, app: AppDay)]   // most first
    }

    private struct Stored: Codable {
        var days: [String: Day]
        var hours: [Bucket]
        var minutes: [Bucket]
    }

    private(set) var days: [String: Day] = [:]   // "2026-10-19", local time
    private var hours: [Bucket] = []             // last 7 days
    private var minutes: [Bucket] = []           // last 2 hours
    private var pendingUsedWh = 0.0              // since the last app scan
    private var pendingWallWh = 0.0
    private var lastPowerTime: Date?
    private var gpuJoules = 0.0                  // GPU energy since the last app scan, shared out by GPU time
    private let meter = AppEnergyMeter()
    private var lastScan = Date()
    private var lastSave = Date()
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("energy.plist")
    }()

    private init() {
        if let data = try? Data(contentsOf: file) {
            if let stored = try? PropertyListDecoder().decode(Stored.self, from: data) {
                days = stored.days
                hours = stored.hours
                minutes = stored.minutes
            } else if let oldFormat = try? PropertyListDecoder().decode([String: Day].self, from: data) {
                days = oldFormat   // v0.16 kept days only
            }
        }
        _ = meter.sinceLastCall(gpuJoules: 0)   // baseline for the per-app counters
    }

    /// Called on every tick with the current power. Adds watts × seconds since the last call.
    func add(_ power: PowerUsage, at date: Date = Date()) {
        defer { lastPowerTime = date }
        guard let last = lastPowerTime else { return }
        let seconds = date.timeIntervalSince(last)
        guard seconds > 0, seconds < 30 else { return }   // a longer gap means the Mac slept: it used next to nothing

        let today = Self.key(date)
        let usedWh = power.system * seconds / 3600
        let wallWh = power.adapter * seconds / 3600
        days[today, default: Day()].usedWh += usedWh
        days[today, default: Day()].wallWh += wallWh
        pendingUsedWh += usedWh
        pendingWallWh += wallWh
        gpuJoules += power.gpu * seconds

        if date.timeIntervalSince(lastScan) >= 60 { scanApps(today) }   // ~9 ms once a minute
        if date.timeIntervalSince(lastSave) > 600 { save() }
    }

    func day(_ date: Date) -> Day? { days[Self.key(date)] }

    /// Energy over the last `range`: minute buckets up to 2 hours, hour buckets beyond.
    func usage(_ range: TimeRange) -> Usage {
        let from = Date().timeIntervalSince1970 - range.seconds
        let buckets = range.seconds <= 7200 ? minutes.filter { $0.start > from }
                                            : hours.filter { $0.start + 3600 > from }
        var apps: [String: AppDay] = [:]
        for bucket in buckets {
            for (key, app) in bucket.apps { apps[key, default: AppDay(name: app.name, wh: 0)].wh += app.wh }
        }
        return Usage(usedWh: buckets.map(\.usedWh).reduce(0, +),
                     wallWh: buckets.map(\.wallWh).reduce(0, +),
                     apps: apps.sorted { $0.value.wh > $1.value.wh }.map { ($0.key, $0.value) })
    }

    func save() {
        lastSave = Date()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Stored(days: days, hours: hours, minutes: minutes)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func scanApps(_ today: String) {
        let now = Date()
        lastScan = now
        var minute = Bucket(start: now.timeIntervalSince1970, usedWh: pendingUsedWh, wallWh: pendingWallWh)
        for (key, used) in meter.sinceLastCall(gpuJoules: gpuJoules) {
            let wh = used.joules / 3600
            days[today, default: Day()].apps[key, default: AppDay(name: used.name, wh: 0)].wh += wh
            minute.apps[key] = AppDay(name: used.name, wh: wh)
        }
        gpuJoules = 0
        pendingUsedWh = 0
        pendingWallWh = 0

        minutes.append(minute)
        minutes.removeAll { $0.start < minute.start - 7200 }

        let hourStart = (minute.start / 3600).rounded(.down) * 3600
        if hours.last?.start != hourStart { hours.append(Bucket(start: hourStart)) }
        hours[hours.count - 1].usedWh += minute.usedWh
        hours[hours.count - 1].wallWh += minute.wallWh
        for (key, app) in minute.apps {
            hours[hours.count - 1].apps[key, default: AppDay(name: app.name, wh: 0)].wh += app.wh
        }
        hours.removeAll { $0.start < hourStart - 7 * 86400 }
        prune()
    }

    /// Daily totals are tiny, so they're kept for 400 days; the per-app detail for 31 days, top 40 apps.
    private func prune() {
        let calendar = Calendar.current
        let totalsCutoff = Self.key(calendar.date(byAdding: .day, value: -400, to: Date())!)
        let appsCutoff = Self.key(calendar.date(byAdding: .day, value: -31, to: Date())!)
        days = days.filter { $0.key >= totalsCutoff }   // "yyyy-MM-dd" sorts like dates
        for (key, day) in days where key < appsCutoff && !day.apps.isEmpty {
            days[key]?.apps = [:]
        }
        for (key, day) in days where day.apps.count > 40 {
            days[key]?.apps = Self.top40(day.apps)
        }
        if let last = hours.indices.last, hours[last].apps.count > 40 {
            hours[last].apps = Self.top40(hours[last].apps)
        }
    }

    private static func top40(_ apps: [String: AppDay]) -> [String: AppDay] {
        Dictionary(uniqueKeysWithValues: apps.sorted { $0.value.wh > $1.value.wh }.prefix(40).map { ($0.key, $0.value) })
    }
}

/// Energy per app between two calls. Process energy and GPU-time counters only ever grow,
/// so nothing is lost between calls, however far apart they are (only processes that
/// start and quit in between are missed).
final class AppEnergyMeter {
    private var cpuBefore: [pid_t: UInt64] = [:]   // nJ
    private var gpuBefore: [pid_t: UInt64] = [:]   // ns of GPU time

    /// Joules per app since the last call. `gpuJoules` is the GPU's energy over the same span;
    /// it's shared out by each app's share of GPU time.
    func sinceLastCall(gpuJoules: Double) -> [String: (name: String, joules: Double)] {
        var cpuByOwner: [pid_t: Double] = [:]
        var cpuNow: [pid_t: UInt64] = [:]
        for pid in Processes.all() {
            guard let usage = Processes.usage(pid) else { continue }
            cpuNow[pid] = usage.ri_energy_nj
            if let before = cpuBefore[pid], usage.ri_energy_nj >= before {
                cpuByOwner[Processes.owner(of: pid), default: 0] += Double(usage.ri_energy_nj - before) / 1e9
            }
        }
        let (gpuNow, gpuNames) = ProcessGPUReader.gpuTimeByProcess()
        var gpuByOwner: [pid_t: Double] = [:]
        for (pid, time) in gpuNow {
            if let before = gpuBefore[pid], time >= before {
                gpuByOwner[Processes.owner(of: pid), default: 0] += Double(time - before)
            }
        }
        cpuBefore = cpuNow
        gpuBefore = gpuNow

        let gpuTotal = gpuByOwner.values.reduce(0, +)
        var result: [String: (name: String, joules: Double)] = [:]
        for owner in Set(cpuByOwner.keys).union(gpuByOwner.keys) {
            let gpuPart = gpuTotal > 0 ? (gpuByOwner[owner] ?? 0) / gpuTotal * gpuJoules : 0
            let joules = (cpuByOwner[owner] ?? 0) + gpuPart
            guard joules > 0 else { continue }
            let app = NSRunningApplication(processIdentifier: owner)
            let name = app?.localizedName ?? gpuNames[owner] ?? Processes.name(owner)
            let key = app?.bundleIdentifier ?? name   // stable across restarts, unlike the pid
            result[key, default: (name, 0)].joules += joules
        }
        return result
    }
}
