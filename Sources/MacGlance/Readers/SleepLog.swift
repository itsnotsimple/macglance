import Foundation

/// One stretch of sleep: from going to sleep until you woke the Mac up yourself.
struct SleepSession: Identifiable {
    let start: Date
    let end: Date
    let startPercent: Int?
    let endPercent: Int?
    let onBattery: Bool          // at the start
    let darkWakes: Int           // brief wake-ups with the screen off
    let awakeSeconds: Int        // time spent in them
    let causes: [String: Int]    // why it woke (scheduled task, network…) → how often
    let wakers: [String: Int]    // which service asked for the scheduled wake-ups (its system name) → how often

    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Battery used while asleep; nil on the charger or without data.
    var percentLost: Int? {
        guard onBattery, let startPercent, let endPercent, startPercent >= endPercent else { return nil }
        return startPercent - endPercent
    }
}

/// What macOS's power log (`pmset -g log`, readable without admin rights) says about sleep.
/// The log holds about a week and is ~10 MB, so it's read only while the Battery page is open,
/// in the background, and kept for 10 minutes.
enum SleepLog {
    private static var cache: (time: Date, sessions: [SleepSession])?

    static func sessions(completion: @escaping ([SleepSession]) -> Void) {
        if let cache, Date().timeIntervalSince(cache.time) < 600 { completion(cache.sessions); return }
        DispatchQueue.global(qos: .background).async {
            let found = parse(readLog())
            DispatchQueue.main.async {
                cache = (Date(), found)
                completion(found)
            }
        }
    }

    private static func readLog() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    /// Lines look like "2026-10-18 15:45:31 +0300 Sleep  <tab>Entering Sleep state due to 'Clamshell Sleep' … Using Batt (Charge:1%) …".
    static func parse(_ log: String) -> [SleepSession] {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var sessions: [SleepSession] = []
        var current: (start: Date, percent: Int?, battery: Bool, dark: Int, awake: Int, causes: [String: Int], wakers: [String: Int])?
        var requests: [(service: String, inSeconds: Int)] = []   // the last "Wake Requests" line, before each sleep

        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 26, let tab = line.firstIndex(of: "\t") else { continue }
            let head = line[..<tab]
            let message = String(line[line.index(after: tab)...])
            let kind = head.dropFirst(25).trimmingCharacters(in: .whitespaces)
            guard kind == "Sleep" || kind == "Wake" || kind == "DarkWake" || kind == "Wake Requests",
                  let time = dateFormat.date(from: String(head.prefix(25))) else { continue }

            switch kind {
            case "Wake Requests":
                requests = wakeRequests(message)
            case "Sleep" where current == nil:
                // The first sleep after you used the Mac starts a session; "back to sleep" lines don't.
                guard !message.contains("Maintenance Sleep"), !message.contains("Back to Sleep") else { continue }
                let (battery, percent) = power(message)
                current = (time, percent, battery, 0, 0, [:], [:])
            case "DarkWake" where current != nil:
                current!.dark += 1
                current!.awake += seconds(message)
                let cause = causeOf(message)
                current!.causes[cause, default: 0] += 1
                if cause == "timer", let first = requests.min(by: { $0.inSeconds < $1.inSeconds }) {
                    current!.wakers[first.service, default: 0] += 1   // the scheduled wake that came due first
                }
            case "Wake" where current != nil:
                if isYou(message) {
                    let (_, percent) = power(message)
                    let s = current!
                    sessions.append(SleepSession(start: s.start, end: time, startPercent: s.percent, endPercent: percent,
                                                 onBattery: s.battery, darkWakes: s.dark, awakeSeconds: s.awake,
                                                 causes: s.causes, wakers: s.wakers))
                    current = nil
                } else {
                    current!.causes["notification", default: 0] += 1   // the screen lit up for a notification
                }
            default:
                break
            }
        }
        return sessions.filter { $0.duration >= 15 * 60 }.reversed()   // newest first; short naps aren't interesting
    }

    /// A wake-up by you: lid, keyboard, trackpad, power button.
    private static func isYou(_ message: String) -> Bool {
        ["HID Activity", "UserActivity", "LidOpen", "Lid Open", "PowerButton", "Power Button", "User"].contains { message.contains($0) }
    }

    /// "Using AC (Charge:80%)" / "Using Batt (Charge:1%)"
    private static func power(_ message: String) -> (battery: Bool, percent: Int?) {
        let battery = message.range(of: "Using Batt", options: .caseInsensitive) != nil
        guard let range = message.range(of: "Charge:") else { return (battery, nil) }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        return (battery, Int(digits))
    }

    /// "… 43 secs"
    private static func seconds(_ message: String) -> Int {
        guard let range = message.range(of: " secs", options: .backwards) else { return 0 }
        let before = message[..<range.lowerBound]
        return Int(before.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
    }

    private static func causeOf(_ message: String) -> String {
        let reason = message.lowercased()
        if reason.contains("rtc") { return "timer" }
        if reason.contains("wifibt") || reason.contains("arpt") || reason.contains("e_tko") { return "network" }
        if reason.contains("batterystatechange") || reason.contains("smc.pow") { return "power" }
        return "other"
    }

    /// "[process=dasd request=SleepService deltaSecs=930 wakeAt=… info="com.apple.dasd:501:com.apple.intelligenceflow…"] [process=…]"
    private static func wakeRequests(_ message: String) -> [(service: String, inSeconds: Int)] {
        message.components(separatedBy: "[process=").dropFirst().compactMap { part in
            let process = String(part.prefix { $0 != " " })
            guard let delta = part.range(of: "deltaSecs=") else { return nil }
            let seconds = Int(part[delta.upperBound...].prefix { $0.isNumber }) ?? Int.max
            var service = process
            if let info = part.range(of: "info=\"") {
                let value = part[info.upperBound...].prefix { $0 != "\"" }
                if let last = value.split(separator: ":").last, !last.isEmpty { service = String(last) }
            }
            return (service, seconds)   // the system name; friendlyName(_:) when showing it
        }
    }

    /// Known background jobs, in words; anything else keeps its own name.
    static func friendlyName(_ service: String) -> String {
        let names: [(String, String, String)] = [
            ("intelligenceflow", "Apple Intelligence", "Apple Intelligence"),
            ("GenerativeFunctions", "Apple Intelligence", "Apple Intelligence"),
            ("imageplaygroundd", "Image Playground (Apple Intelligence)", "Image Playground (Apple Intelligence)"),
            ("calaccessd", "Календар", "Calendar"),
            ("DHCP", "Мрежа (DHCP)", "Network (DHCP)"),
            ("ScreenTimeAgent", "Screen Time", "Screen Time"),
            ("com.apple.obc", "Оптимизирано зареждане", "Optimized Battery Charging"),
            ("mDNSResponder", "Мрежа (Bonjour)", "Network (Bonjour)"),
            ("backupd", "Time Machine", "Time Machine"),
            ("softwareupdate", "Обновления на macOS", "macOS updates"),
            ("com.apple.mail", "Mail", "Mail"),
            ("photoanalysisd", "Снимки", "Photos"),
            ("cloudphotod", "iCloud Снимки", "iCloud Photos"),
            ("powerd", "Управление на захранването", "Power management"),
        ]
        for (needle, bg, en) in names where service.contains(needle) { return tr(bg, en) }
        // "com.apple.alarm.user-invisible-com.apple.acmd.alarm,338" → "com.apple.acmd.alarm"
        var name = service.replacingOccurrences(of: "com.apple.alarm.user-invisible-", with: "")
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        return name
    }
}
