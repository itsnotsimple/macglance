import Foundation

/// Who writes to the SSD right now, per app, in bytes per second: the "Now" view of the Disk page.
/// Runs only while that view is on screen: every 2 seconds one look at every process's write
/// counter (~5 ms); the difference since the last look is the speed. Like DiskWriters, macOS's
/// root processes (swap, part of Spotlight) can't be read; the page shows them as "The rest".
final class LiveWriters: ObservableObject {
    static let shared = LiveWriters()

    struct Row: Identifiable {
        let id: String        // the name shown
        let key: String       // bundle id, or the process name
        let icon: String?     // a bundle id to take the icon from
        let perSecond: Double
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var ready = false   // false until two looks give a first speed
    private var timer: Timer?
    private var last: (time: Date, written: [String: Reading])?
    private let queue = DispatchQueue(label: "macglance.livewriters", qos: .utility)

    private struct Reading {
        let pid: pid_t
        let bytes: Double
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
        rows = []
        ready = false
    }

    private func sample() {
        queue.async { [weak self] in
            let time = Date()
            var now: [String: Reading] = [:]
            for pid in Processes.all() {
                guard let usage = Processes.usage(pid) else { continue }   // root processes need admin rights
                now["\(pid)-\(usage.ri_proc_start_abstime)"] = Reading(pid: pid, bytes: Double(usage.ri_diskio_byteswritten))
            }
            DispatchQueue.main.async { self?.take(time, now) }
        }
    }

    private func take(_ time: Date, _ now: [String: Reading]) {
        guard timer != nil else { return }   // stopped while reading
        let previous = last
        last = (time, now)
        guard let previous else { return }
        let seconds = time.timeIntervalSince(previous.time)
        guard seconds > 0.5 else { return }

        // Per responsible app, like the daily list: Brave's helpers count as Brave.
        // A process seen for the first time counts from its next look.
        var owners: [pid_t: (bytes: Double, name: String)] = [:]
        for (key, reading) in now {
            guard let before = previous.written[key]?.bytes, reading.bytes > before else { continue }
            owners[Processes.owner(of: reading.pid), default: (0, Processes.name(reading.pid))].bytes += reading.bytes - before
        }
        var totals: [String: (key: String, icon: String?, bytes: Double)] = [:]
        for (owner, change) in owners {
            let (key, name) = ProcessNames.identify(owner: owner, fallback: change.name)
            guard !key.isEmpty else { continue }
            let label = ProcessNames.label(key: key, name: name)
            totals[label.name, default: (key, label.icon, 0)].bytes += change.bytes
        }
        rows = totals.map { Row(id: $0.key, key: $0.value.key, icon: $0.value.icon, perSecond: $0.value.bytes / seconds) }
            .filter { $0.perSecond >= 10_000 }   // under 10 KB/s is noise
            .sorted { $0.perSecond > $1.perSecond }
            .prefix(10)
            .map { $0 }
        ready = true
    }
}
