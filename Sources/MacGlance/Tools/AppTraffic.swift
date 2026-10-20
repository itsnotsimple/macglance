import AppKit
import Network

/// Network traffic per app, per day, with the part on mobile data (an iPhone hotspot) counted
/// separately. macOS's own `nettop` reports bytes per process without admin rights; one copy runs
/// in the background and prints what changed every 30 s (short downloads included). A network that
/// macOS marks as "expensive", which a hotspot is, counts as mobile data.
final class AppTraffic: ObservableObject {
    static let shared = AppTraffic()

    struct Usage: Codable {
        var name: String
        var down = 0.0
        var up = 0.0
        var mobileDown = 0.0
        var mobileUp = 0.0
        var total: Double { down + up }
        var mobile: Double { mobileDown + mobileUp }
    }

    @Published private(set) var today: [String: Usage] = [:]   // key: bundle id, or the process name
    @Published private(set) var onMobileData = false
    private var days: [String: [String: Usage]] = [:]          // "2026-10-20" → apps
    private var nettop: Process?
    private var keepOpen: Pipe?                 // nettop's input: must stay open, see start()
    private var watchdog: Timer?
    private var lastCPU: Double?                // seconds of CPU nettop had used at the last check
    private var disabled = false                // the watchdog stopped it for good
    private var buffer = ""
    private var block: [(pid: pid_t, name: String, down: Double, up: Double)] = []
    private var blocksSeen = 0
    private var lastSave = Date()
    private let monitor = NWPathMonitor()
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("traffic.plist")
    }()

    private init() {
        if let data = try? Data(contentsOf: file),
           let stored = try? PropertyListDecoder().decode([String: [String: Usage]].self, from: data) {
            days = stored
        }
        today = days[EnergyLedger.key(Date())] ?? [:]
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.onMobileData = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "macglance.path"))
    }

    /// Today's apps, most data first.
    var todaySorted: [(key: String, usage: Usage)] {
        today.sorted { $0.value.total > $1.value.total }.map { ($0.key, $0.value) }
    }

    var mobileToday: Double { today.values.map(\.mobile).reduce(0, +) }

    // MARK: - The background nettop

    func start() {
        guard nettop == nil, !disabled else { return }
        let process = Process()
        // `script` gives nettop a terminal, so it prints each line right away instead of holding
        // ~4 KB (several minutes) in a buffer as it does when writing to a pipe.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // nettop: -P per process, -d changes since the last print, -L 0 forever, every 30 s, just the byte counts
        process.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-P", "-d", "-L", "0", "-s", "30",
                             "-J", "bytes_in,bytes_out", "-x"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Its input must be a pipe that stays open. With /dev/null (or a closed input) `script` passes
        // an end-of-input to nettop, which then spins at 100%+ CPU trying to read its terminal.
        let input = Pipe()
        process.standardInput = input
        keepOpen = input
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }   // nettop ended
            self?.receive(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {   // it died: try again in a minute
                self?.nettop = nil
                self?.keepOpen = nil
                self?.start()
            }
        }
        do {
            try process.run()
            nettop = process
            lastCPU = nil
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkCPU() }
        } catch {
            NSLog("MacGlance: nettop didn't start: \(error)")
        }
    }

    /// When MacGlance quits. (If MacGlance crashes, nettop gets a broken pipe on its next print and exits.)
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        nettop?.terminationHandler = nil
        nettop?.terminate()
        nettop = nil
        keepOpen = nil
        save()
    }

    /// The safety net: MacGlance must stay light. If nettop (and the `script` around it) used more than
    /// 5 s of CPU in the last minute, something is wrong: stop it for good and log why.
    private func checkCPU() {
        guard let wrapper = nettop?.processIdentifier else { return }
        var children = [pid_t](repeating: 0, count: 8)
        let count = Int(proc_listchildpids(wrapper, &children, Int32(children.count * MemoryLayout<pid_t>.size)))
        let pids = [wrapper] + children.prefix(max(0, count))
        let ticks = pids.compactMap(Processes.usage).map { Double($0.ri_user_time + $0.ri_system_time) }.reduce(0, +)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let seconds = ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
        defer { lastCPU = seconds }
        guard let last = lastCPU, seconds - last > 5 else { return }
        NSLog("MacGlance: nettop used \(Int(seconds - last)) s of CPU in a minute; per-app data is off until the next launch")
        disabled = true
        stop()
    }

    /// Runs on the pipe's thread. Lines look like "Safari.1234,52311,8812,"; a ",bytes_in,bytes_out,"
    /// header starts each print. The first print is totals since each process started, so it's skipped.
    private func receive(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(where: \.isNewline) {   // "\r\n" is one Character in Swift, so not == "\n"
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)   // the terminal adds \r
            buffer.removeSubrange(...newline)
            if line.contains(",bytes_in,") {   // (the very first one can start with a stray ^D)
                let finished = block
                block = []
                blocksSeen += 1
                if blocksSeen > 2 {   // block 1 = totals; from block 2 on, changes (empty ones too: quiet time counts)
                    DispatchQueue.main.async { self.add(finished) }
                }
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let down = Double(fields[1]), let up = Double(fields[2]), down + up > 0 else { continue }
            block.append((pid, String(fields[0][..<dot]), down, up))   // nettop's name: kept for processes that end
        }
    }

    private func add(_ changes: [(pid: pid_t, name: String, down: Double, up: Double)]) {
        let day = EnergyLedger.key(Date())
        if days[day] == nil { today = [:] }   // a new day
        var apps = days[day] ?? [:]
        let mobile = onMobileData
        var block: [String: (name: String, down: Double, up: Double)] = [:]   // this print, per app: for the charts
        for change in changes {
            let (key, name) = ProcessNames.identify(owner: Processes.owner(of: change.pid), fallback: change.name)   // ended already: nettop's name
            guard !key.isEmpty else { continue }
            block[key, default: (name, 0, 0)].down += change.down
            block[key, default: (name, 0, 0)].up += change.up
            var usage = apps[key] ?? Usage(name: name)
            usage.down += change.down
            usage.up += change.up
            if mobile {
                usage.mobileDown += change.down
                usage.mobileUp += change.up
            }
            apps[key] = usage
        }
        days[day] = apps
        today = apps
        // Who downloaded and uploaded, for the Network charts. Under 1 KB/s isn't worth keeping.
        AppHistory.shared.record(.down, at: Date(), duration: 30, block.filter { $0.value.down >= 30_000 }.map { ($0.key, $0.value.name, $0.value.down) })
        AppHistory.shared.record(.up, at: Date(), duration: 30, block.filter { $0.value.up >= 30_000 }.map { ($0.key, $0.value.name, $0.value.up) })
        if Date().timeIntervalSince(lastSave) > 600 { save() }
    }

    func save() {
        lastSave = Date()
        let cutoff = EnergyLedger.key(Calendar.current.date(byAdding: .day, value: -31, to: Date()) ?? Date())
        days = days.filter { $0.key >= cutoff }   // a month is plenty
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(days) { try? data.write(to: file, options: .atomic) }
    }
}
