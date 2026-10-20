import AppKit
import CSensors

/// Who writes to the SSD, per app, per day. The kernel counts the bytes every process has written
/// to disk (ri_diskio_byteswritten); once a minute MacGlance reads them all (~4 ms) and adds what's
/// new to today. Processes of macOS's root user (swap, part of Spotlight, Time Machine) can't be
/// read without admin rights, so they're missing here; the SSD's own "written today" has them.
final class DiskWriters: ObservableObject {
    static let shared = DiskWriters()

    struct Writer: Codable {
        var name: String
        var bytes = 0.0
    }

    /// A row in the list: known macOS processes merged under one name.
    struct Row: Identifiable {
        let id: String       // the name shown
        let icon: String?    // a bundle id to take the icon from
        let bytes: Double
    }

    @Published private(set) var today: [String: Writer] = [:]   // key: bundle id, or the process name
    private(set) var countingSince = Date()
    private var days: [String: [String: Writer]] = [:]          // "2026-10-20" → apps
    private var seen: [String: Double] = [:]                    // "pid-start" → bytes it had written at the last look
    private var ssdAtStart: [String: Double] = [:]              // day → the SSD's own lifetime counter at its first look
    private var ssdNow: Double?
    private var lastSample: Date?
    private var timer: Timer?
    private var lastSave = Date()
    private let queue = DispatchQueue(label: "macglance.diskwriters", qos: .utility)
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("diskwriters.plist")
    }()

    /// What's kept between launches. `seen` too, so an update or a restart doesn't count the same bytes twice.
    private struct Stored: Codable {
        var days: [String: [String: Writer]]
        var seen: [String: Double]
        var since: Date
        var ssdAtStart: [String: Double]?
        var lastSample: Date?
    }

    private init() {
        if let data = try? Data(contentsOf: file), let stored = try? PropertyListDecoder().decode(Stored.self, from: data) {
            days = stored.days
            seen = stored.seen
            countingSince = stored.since
            ssdAtStart = stored.ssdAtStart ?? [:]
            lastSample = stored.lastSample
        }
        today = days[EnergyLedger.key(Date())] ?? [:]
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 10   // lets macOS run it together with other wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        save()
    }

    // MARK: - Counting

    /// Reads every process in the background, then names the owners on the main thread.
    private func sample() {
        let seen = self.seen, previous = lastSample, now = Date()
        queue.async { [weak self] in
            var current: [String: Double] = [:]
            var added: [pid_t: (bytes: Double, name: String)] = [:]   // per owner
            for pid in Processes.all() {
                guard let usage = Processes.usage(pid) else { continue }   // root processes need admin rights
                let written = Double(usage.ri_diskio_byteswritten)
                let key = "\(pid)-\(usage.ri_proc_start_abstime)"
                current[key] = written
                // New since the last look: all it wrote counts. Already running at the very first look
                // (a fresh install): only what comes next, so the list starts together with the SSD's count.
                let before = seen[key] ?? (previous.map { (Processes.started(pid) ?? .distantPast) >= $0 } == true ? 0 : written)
                guard written > before else { continue }
                let owner = Processes.owner(of: pid)
                added[owner, default: (0, Processes.name(pid))].bytes += written - before
            }
            var smart = SSDSmart()
            let ssd = ssd_smart(&smart) ? smart.bytesWritten : nil   // 0.4 ms
            DispatchQueue.main.async { self?.add(added, seen: current, ssd: ssd, at: now) }
        }
    }

    private func add(_ added: [pid_t: (bytes: Double, name: String)], seen current: [String: Double], ssd: Double?, at time: Date) {
        seen = current
        lastSample = time
        let day = EnergyLedger.key(Date())
        if let ssd {   // nil if another app was reading it that very moment
            ssdNow = ssd
            if ssdAtStart[day] == nil { ssdAtStart[day] = ssd }
        }
        var apps = days[day] ?? [:]
        for (owner, change) in added {
            let app = NSRunningApplication(processIdentifier: owner)
            let ownerName = Processes.name(owner)
            let name = app?.localizedName ?? (ownerName.isEmpty ? change.name : ownerName)   // the owner ended: the process's own name
            let key = app?.bundleIdentifier ?? name
            guard !key.isEmpty else { continue }
            apps[key, default: Writer(name: name)].bytes += change.bytes
        }
        days[day] = apps
        today = apps
        if Date().timeIntervalSince(lastSave) > 600 { save() }
    }

    func save() {
        lastSave = Date()
        let cutoff = EnergyLedger.key(Calendar.current.date(byAdding: .day, value: -31, to: Date()) ?? Date())
        days = days.filter { $0.key >= cutoff }   // a month is plenty
        ssdAtStart = ssdAtStart.filter { $0.key >= cutoff }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Stored(days: days, seen: seen, since: countingSince, ssdAtStart: ssdAtStart, lastSample: lastSample)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: - The list

    /// The day keys of the last `count` days, today first.
    private func keys(_ count: Int) -> [String] {
        (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()).map(EnergyLedger.key) }
    }

    /// Everything the apps wrote over the last `count` days.
    func total(days count: Int) -> Double {
        keys(count).compactMap { days[$0] }.flatMap(\.values).map(\.bytes).reduce(0, +)
    }

    /// What the SSD itself counted over the same days (from MacGlance's first look on the earliest of them).
    /// It includes what the list can't see: macOS's root processes and programs that ended within a minute.
    func ssdWritten(days count: Int) -> Double? {
        guard let now = ssdNow, let start = keys(count).reversed().compactMap({ ssdAtStart[$0] }).first, now >= start else { return nil }
        return now - start
    }

    /// The biggest writers over the last `count` days (1 = today), at least 1 MB each.
    func top(days count: Int, limit: Int = 10) -> [Row] {
        var totals: [String: (icon: String?, bytes: Double)] = [:]
        for key in keys(count) {
            guard let apps = days[key] else { continue }
            for (key, writer) in apps {
                let label = Self.label(key: key, name: writer.name)
                totals[label.name, default: (label.icon, 0)].bytes += writer.bytes
            }
        }
        return totals.filter { $0.value.bytes >= 1e6 }
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { Row(id: $0.key, icon: $0.value.icon, bytes: $0.value.bytes) }
    }

    /// macOS's background processes in words, with the icon of the app they work for;
    /// apps and anything unknown keep their own name.
    private static func label(key: String, name: String) -> (name: String, icon: String?) {
        let known: [([String], String, String, String?)] = [
            (["IMDPersistenceAgent", "imagent"], "Съобщения", "Messages", "com.apple.MobileSMS"),
            (["identityservicesd"], "iMessage и FaceTime", "iMessage and FaceTime", "com.apple.FaceTime"),
            (["corespotlightd", "spotlightknowledge", "mdworker", "mdbulkimport", "parsecd"],
             "Spotlight (индекс за търсене)", "Spotlight (search index)", "com.apple.Spotlight"),
            (["appstoreagent", "storedownloadd", "storeassetd", "appstorecomponentsd"], "App Store", "App Store", "com.apple.AppStore"),
            (["photolibraryd", "photoanalysisd", "mediaanalysisd", "cloudphotod"], "Снимки", "Photos", "com.apple.Photos"),
            (["com.apple.Safari.SafeBrowsing"], "Safari (Safe Browsing)", "Safari (Safe Browsing)", "com.apple.Safari"),
            (["AMPLibraryAgent", "AMPArtworkAgent"], "Музика", "Music", "com.apple.Music"),
            (["calaccessd"], "Календар", "Calendar", "com.apple.iCal"),
            (["contactsd", "AddressBookSourceSync"], "Контакти", "Contacts", "com.apple.AddressBook"),
            (["remindd"], "Напомняния", "Reminders", "com.apple.reminders"),
            (["cloudd", "bird", "fileproviderd"], "iCloud", "iCloud", nil),
            (["chronod"], "Уиджети", "Widgets", nil),
            (["duetexpertd", "suggestd"], "Предложения на Siri", "Siri Suggestions", nil),
            (["knowledge-agent", "BiomeAgent", "biomesyncd"], "История на ползването (Screen Time, Siri)", "Usage history (Screen Time, Siri)", nil),
            (["intelligenceplatformd", "intelligenceflowd", "generativeexperiencesd"], "Apple Intelligence", "Apple Intelligence", nil),
            (["lsd"], "Списък с приложенията на macOS (lsd)", "macOS's list of apps (lsd)", nil),
            (["cfprefsd"], "Настройки на приложенията (cfprefsd)", "App settings (cfprefsd)", nil),
            (["nsurlsessiond"], "Изтегляния на заден план", "Background downloads", nil),
        ]
        let candidates = [key, name, key.components(separatedBy: ".").last ?? key]
        for (needles, bg, en, icon) in known
        where needles.contains(where: { needle in candidates.contains { $0 == needle || ($0.hasPrefix(needle) && needle.count > 4) } }) {
            return (tr(bg, en), icon)
        }
        return (name, key.contains(".") ? key : nil)   // an app: its bundle id gives the icon
    }
}
