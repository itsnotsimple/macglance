import Foundation

/// Who used the most, minute by minute over the last 7 days, so a chart can say who caused a spike:
/// CPU, energy and GPU from the once-a-minute look (MinuteSampler), download and upload from nettop
/// (AppTraffic). Only the top 3 apps of each minute are kept, as plain numbers in one block of bytes
/// per kind: about 1 MB for a busy week, saved and loaded in a few milliseconds.
final class AppHistory {
    static let shared = AppHistory()

    enum Kind: Int, CaseIterable {
        case cpu, power, gpu, down, up
    }

    /// One minute (or one nettop print) of one kind: the stretch it covers and up to three apps with
    /// their amounts (CPU seconds, joules, GPU seconds or bytes). `app` is an index into `apps`.
    private struct Record {
        var time: Double = 0        // when it ended, seconds since 1970
        var duration: Float = 0     // seconds it covers
        var app0 = UInt16.max, app1 = UInt16.max, app2 = UInt16.max   // .max = none
        var amount0: Float = 0, amount1: Float = 0, amount2: Float = 0

        var entries: [(app: UInt16, amount: Float)] {
            [(app0, amount0), (app1, amount1), (app2, amount2)].filter { $0.app != .max }
        }
    }

    private var records: [Kind: [Record]] = [:]
    private var apps: [(key: String, name: String)] = []
    private var appIndex: [String: UInt16] = [:]
    private var previous: MinuteSampler.Snapshot?
    private var lastSave = Date()
    private static let kept: TimeInterval = 7 * 86400
    private static let formatVersion = 1
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("apphistory.plist")
    }()

    private init() {
        load()
    }

    // MARK: - Recording

    /// CPU, energy and GPU per app since the previous look. After sleep (or the first look) it only takes a new baseline.
    func take(_ snapshot: MinuteSampler.Snapshot) {
        defer { previous = snapshot }
        guard let previous else { return }
        let seconds = snapshot.time.timeIntervalSince(previous.time)
        guard seconds > 10, seconds < 180 else { return }   // asleep in between: the counters span hours

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
        let before = Dictionary(previous.processes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var cpu: [pid_t: (amount: Double, name: String)] = [:]      // CPU seconds per owner
        var energy: [pid_t: (amount: Double, name: String)] = [:]   // joules per owner
        for process in snapshot.processes {
            guard let old = before[process.key] else { continue }   // new processes count from the next look
            let owner = Processes.owner(of: process.pid)
            if process.cpu > old.cpu {
                cpu[owner, default: (0, "")].amount += Double(process.cpu - old.cpu) * nanosPerTick / 1e9
            }
            if process.energy > old.energy {
                energy[owner, default: (0, "")].amount += Double(process.energy - old.energy) / 1e9
            }
        }
        var gpu: [pid_t: (amount: Double, name: String)] = [:]      // GPU seconds per owner
        for (pid, nanos) in snapshot.gpu {
            guard let old = previous.gpu[pid], nanos > old else { continue }
            gpu[Processes.owner(of: pid), default: (0, snapshot.gpuNames[pid] ?? "")].amount += Double(nanos - old) / 1e9
        }
        // Small amounts aren't worth keeping: under 0.5% of a core, 0.05 W, 0.5% of the GPU.
        record(.cpu, at: snapshot.time, duration: seconds, top(cpu, minimum: 0.005 * seconds))
        record(.power, at: snapshot.time, duration: seconds, top(energy, minimum: 0.05 * seconds))
        record(.gpu, at: snapshot.time, duration: seconds, top(gpu, minimum: 0.005 * seconds))
        if Date().timeIntervalSince(lastSave) > 600 { save() }
    }

    /// The three biggest owners, named (only those three get looked up), merged if they're the same app.
    private func top(_ amounts: [pid_t: (amount: Double, name: String)], minimum: Double) -> [(key: String, name: String, amount: Double)] {
        var merged: [String: (name: String, amount: Double)] = [:]
        for (owner, entry) in amounts.filter({ $0.value.amount >= minimum }).sorted(by: { $0.value.amount > $1.value.amount }).prefix(5) {
            let fallback = entry.name.isEmpty ? Processes.name(owner) : entry.name
            let (key, name) = ProcessNames.identify(owner: owner, fallback: fallback)
            guard !key.isEmpty else { continue }
            merged[key, default: (name, 0)].amount += entry.amount
        }
        return merged.map { ($0.key, $0.value.name, $0.value.amount) }
    }

    /// Adds a stretch of `duration` seconds that ended at `time`; keeps the three biggest amounts.
    /// A stretch with no apps is kept too: charts average over the time covered.
    func record(_ kind: Kind, at time: Date, duration: Double, _ amounts: [(key: String, name: String, amount: Double)]) {
        var entry = Record(time: time.timeIntervalSince1970, duration: Float(duration))
        let top = amounts.sorted { $0.amount > $1.amount }.prefix(3).map { (index(of: $0.key, name: $0.name), Float($0.amount)) }
        if top.count > 0 { (entry.app0, entry.amount0) = top[0] }
        if top.count > 1 { (entry.app1, entry.amount1) = top[1] }
        if top.count > 2 { (entry.app2, entry.amount2) = top[2] }
        records[kind, default: []].append(entry)
    }

    private func index(of key: String, name: String) -> UInt16 {
        if let index = appIndex[key] { return index }
        guard apps.count < Int(UInt16.max) - 1 else { return .max }
        apps.append((key, name))
        appIndex[key] = UInt16(apps.count - 1)
        return UInt16(apps.count - 1)
    }

    // MARK: - Reading

    /// The apps that used the most between `from` and `to`, in the chart's own unit: % of the whole CPU,
    /// watts, % of the GPU, or bytes per second. Averaged over the time covered, like the chart's line.
    func top(_ kind: Kind, from: TimeInterval, to: TimeInterval, count: Int = 3) -> [(name: String, value: Double)] {
        let list = records[kind] ?? []
        // The first stretch that ends after `from` (they're in time order).
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].time <= from { low = middle + 1 } else { high = middle }
        }
        var covered = 0.0
        var perApp: [UInt16: Double] = [:]
        for record in list[low...] {
            if record.time - Double(record.duration) >= to { break }   // starts after the stretch
            covered += Double(record.duration)
            for entry in record.entries { perApp[entry.app, default: 0] += Double(entry.amount) }
        }
        guard covered > 0 else { return [] }
        var amounts: [String: Double] = [:]   // per name shown, so e.g. Spotlight's helpers add up
        for (index, amount) in perApp where Int(index) < apps.count {
            let app = apps[Int(index)]
            amounts[ProcessNames.label(key: app.key, name: app.name).name, default: 0] += amount
        }
        let scale: Double = switch kind {
        case .cpu: 100 / Double(ProcessInfo.processInfo.activeProcessorCount)   // CPU seconds → % of all cores
        case .gpu: 100
        case .power, .down, .up: 1
        }
        return amounts.map { ($0.key, $0.value / covered * scale) }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { $0 }
    }

    // MARK: - On disk

    private struct Stored: Codable {
        var version: Int
        var recordSize: Int
        var apps: [[String]]          // [key, name]
        var records: [String: Data]   // kind → its records as raw bytes
    }

    func save() {
        lastSave = Date()
        let cutoff = Date().timeIntervalSince1970 - Self.kept
        for kind in records.keys {
            let stale = records[kind]!.prefix { $0.time < cutoff }.count
            if stale > 0 { records[kind]!.removeFirst(stale) }
        }
        let stored = Stored(version: Self.formatVersion, recordSize: MemoryLayout<Record>.stride,
                            apps: apps.map { [$0.key, $0.name] },
                            records: Dictionary(uniqueKeysWithValues: records.map { kind, list in
                                (String(kind.rawValue), list.withUnsafeBytes { Data($0) })
                            }))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(stored) { try? data.write(to: file, options: .atomic) }
    }

    /// Reads the file and drops apps no record mentions any more, so the name list doesn't grow forever.
    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
              stored.version == Self.formatVersion, stored.recordSize == MemoryLayout<Record>.stride else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.kept
        var loaded: [Kind: [Record]] = [:]
        for (raw, bytes) in stored.records {
            guard let kind = Int(raw).flatMap(Kind.init) else { continue }
            var list = [Record](repeating: Record(), count: bytes.count / MemoryLayout<Record>.stride)
            _ = list.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
            loaded[kind] = list.filter { $0.time >= cutoff }
        }
        let oldApps = stored.apps.filter { $0.count == 2 }.map { (key: $0[0], name: $0[1]) }
        var remap: [UInt16: UInt16] = [:]
        func moved(_ old: UInt16) -> UInt16 {
            guard old != .max, Int(old) < oldApps.count else { return .max }
            if let new = remap[old] { return new }
            let new = index(of: oldApps[Int(old)].key, name: oldApps[Int(old)].name)
            remap[old] = new
            return new
        }
        for (kind, list) in loaded {
            records[kind] = list.map { record in
                var record = record
                record.app0 = moved(record.app0)
                record.app1 = moved(record.app1)
                record.app2 = moved(record.app2)
                return record
            }
        }
    }
}

extension Metric {
    /// Whose usage explains this chart: the CPU's and GPU's own load, energy for watts and for heat, traffic for the network.
    var appHistoryKind: AppHistory.Kind {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .power, .cpuTemperature: .power
        case .networkDown: .down
        case .networkUp: .up
        }
    }
}
