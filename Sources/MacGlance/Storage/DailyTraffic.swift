import Foundation

/// How much was downloaded and uploaded today. Adds up the change of the interface
/// counters on every tick, so a reboot (which resets the counters) loses nothing.
final class DailyTraffic {
    static let shared = DailyTraffic()

    private(set) var down: Double   // bytes today
    private(set) var up: Double
    private var day: String
    private var previous: (down: UInt64, up: UInt64)?
    private var lastSave = Date()
    private let defaults = UserDefaults.standard

    private init() {
        day = defaults.string(forKey: "trafficDay") ?? ""
        down = defaults.double(forKey: "trafficDown")
        up = defaults.double(forKey: "trafficUp")
    }

    func update(_ usage: NetworkUsage) {
        defer { previous = (usage.totalDown, usage.totalUp) }
        let today = EnergyLedger.key(Date())
        if today != day {
            day = today
            down = 0
            up = 0
        }
        // first call, or the counters went back to zero (reboot): just take the new baseline
        guard let previous, usage.totalDown >= previous.down, usage.totalUp >= previous.up else { return }
        down += Double(usage.totalDown - previous.down)
        up += Double(usage.totalUp - previous.up)
        if Date().timeIntervalSince(lastSave) > 60 { save() }
    }

    func save() {
        lastSave = Date()
        defaults.set(day, forKey: "trafficDay")
        defaults.set(down, forKey: "trafficDown")
        defaults.set(up, forKey: "trafficUp")
    }
}
