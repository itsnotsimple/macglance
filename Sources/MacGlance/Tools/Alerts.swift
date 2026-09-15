import CSensors
import Foundation

/// Watches for problems in the background and sends a notification. Each problem is reported
/// once, until it clears, and the same kind never more often than every 30 minutes.
/// The checks are spread out to stay light: memory every 10 s, the charger every 30 s,
/// battery heat and runaway processes once a minute.
final class Alerts {
    static let shared = Alerts()

    private enum Kind { case runaway, memory, charger, batteryHot, thermal }

    private let settings = Settings.shared
    private let processes = ProcessCPUReader()
    private let battery = BatteryReader()
    private let temperatures = TemperatureReader()
    private let appMemory = AppMemoryReader()
    private var lastCheck: [Kind: Date] = [:]
    private var lastSent: [Kind: Date] = [:]
    private var active: Set<Kind> = []                                // reported and not cleared yet
    private var busySince: [pid_t: Date] = [:]                         // apps above 90% CPU, since when
    private var reportedRunaways: Set<pid_t> = []
    private var weakChargerSince: Date?
    private let runawayAfter: TimeInterval
    private let post: (_ title: String, _ body: String) -> Void

    /// The defaults are the real ones; a test can shorten the wait and print instead of notifying.
    init(runawayAfter: TimeInterval = 300,
         post: @escaping (_ title: String, _ body: String) -> Void = { Notifier.shared.post(title: $0, body: $1) }) {
        self.runawayAfter = runawayAfter
        self.post = post
    }

    /// Called on every tick of the menu bar.
    func tick() {
        if due(.memory, every: 10) { checkMemory() }
        if due(.thermal, every: 10) { checkThermal() }
        if due(.charger, every: 30) { checkCharger() }
        if due(.batteryHot, every: 60) { checkBatteryHeat() }
        if due(.runaway, every: 60) { checkRunaways() }
    }

    // MARK: - Checks

    func checkMemory() {
        guard settings.alertMemory else { return }
        let pressure = MemoryReader.pressure()
        guard pressure != .normal else { active.remove(.memory); return }
        let level = pressure == .critical ? tr("критичен", "critical") : tr("повишен", "elevated")
        var body = tr("Натискът върху паметта е \(level).", "Memory pressure is \(level).")
        if let biggest = appMemory.top(1).first {   // ~14 ms, only when there's something to report
            body += tr(" Най-много държи \(biggest.app.localizedName ?? "?") (\(memoryText(biggest.bytes))). Затвори нещо, което не ползваш.",
                       " \(biggest.app.localizedName ?? "?") holds the most (\(memoryText(biggest.bytes))). Quit something you're not using.")
        }
        send(.memory, title: tr("Паметта не стига", "Memory is running short"), body: body)
    }

    func checkThermal() {
        guard settings.alertThermal else { return }
        let level = Int(thermal_pressure_level())
        if level < 1 { active.remove(.thermal) }
        guard level >= 2 else { return }
        send(.thermal, title: tr("Макът забавя процесора заради топлината", "The Mac is slowing down because of heat"),
             body: tr("Чипът работи по-бавно, за да се охлади. Махни Мака от меки повърхности и слънце, затвори тежките неща.",
                      "The chip runs slower to cool off. Move the Mac off soft surfaces and out of the sun, quit heavy apps."))
    }

    func checkCharger() {
        guard settings.alertCharger, let info = battery.read() else { return }
        guard info.isPluggedIn, info.watts < -0.5 else {
            weakChargerSince = nil
            active.remove(.charger)
            return
        }
        let since = weakChargerSince ?? Date()
        weakChargerSince = since
        guard Date().timeIntervalSince(since) >= 120 else { return }   // a short spike is normal
        let rating = info.adapterWatts.map { " (\($0) W)" } ?? ""
        send(.charger, title: tr("Зарядното не стига", "The charger can't keep up"),
             body: tr("Макът гълта повече, отколкото зарядното\(rating) дава, и батерията пада, макар и включен.",
                      "The Mac uses more than the charger\(rating) gives, so the battery drains while plugged in."))
    }

    func checkBatteryHeat() {
        guard settings.alertBatteryHot, let temperature = temperatures.batteryTemperature() else { return }
        if temperature < 37 { active.remove(.batteryHot) }   // a little below the limit, so it doesn't flap
        guard temperature >= 40 else { return }
        send(.batteryHot, title: tr("Батерията е гореща", "The battery is hot"),
             body: tr("\(degrees(temperature)): топлината я износва най-бързо. Махни Мака от меки повърхности и слънце, затвори тежките неща.",
                      "\(degrees(temperature)): heat wears it out fastest. Move the Mac off soft surfaces and out of the sun, quit heavy apps."))
    }

    /// An app that keeps one core fully busy for 5 minutes straight is usually stuck.
    func checkRunaways() {
        guard settings.alertRunaway else { return }
        let now = Date()
        let busy = processes.top(20).filter { $0.percent >= 90 }   // average over the last minute
        busySince = busySince.filter { pid, _ in busy.contains { $0.id == pid } }
        reportedRunaways = reportedRunaways.filter { pid in busy.contains { $0.id == pid } }
        for process in busy {
            let since = busySince[process.id] ?? now
            busySince[process.id] = since
            guard now.timeIntervalSince(since) >= runawayAfter, !reportedRunaways.contains(process.id) else { continue }
            reportedRunaways.insert(process.id)
            let minutes = max(1, Int(runawayAfter / 60))
            active.remove(.runaway)   // each stuck app gets its own notification
            send(.runaway, title: tr("\(process.name) натоварва процесора", "\(process.name) is keeping the CPU busy"),
                 body: tr("Вече \(minutes) мин. на \(String(format: "%.0f", process.percent))%. Ако не го ползваш, затвори го: изтощава батерията и грее Мака.",
                          "At \(String(format: "%.0f", process.percent))% for \(minutes) min now. If you're not using it, quit it: it drains the battery and heats the Mac."))
        }
    }

    // MARK: - Helpers

    private func due(_ kind: Kind, every seconds: TimeInterval) -> Bool {
        guard Date().timeIntervalSince(lastCheck[kind] ?? .distantPast) >= seconds else { return false }
        lastCheck[kind] = Date()
        return true
    }

    private func send(_ kind: Kind, title: String, body: String) {
        guard !active.contains(kind),
              Date().timeIntervalSince(lastSent[kind] ?? .distantPast) >= 1800 || kind == .runaway else { return }
        active.insert(kind)
        lastSent[kind] = Date()
        post(title, body)
    }
}
