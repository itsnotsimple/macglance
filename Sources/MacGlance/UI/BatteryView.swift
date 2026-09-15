import AppKit
import SwiftUI

/// Live data for the Battery page. Refreshes only while the page is on screen.
final class BatteryModel: ObservableObject {
    /// Desktop Macs have no battery: the page is then left out of the sidebar.
    static let hasBattery = BatteryReader().read() != nil

    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var temperature: Double?
    @Published private(set) var powerUsage: PowerUsage?
    @Published private(set) var appleHealth: (maximumCapacity: String, condition: String)?
    @Published private(set) var tips: [BatteryTip] = []
    private let reader = BatteryReader()
    private let temperatures = TemperatureReader()
    private let power = PowerReader()
    private let processes = ProcessCPUReader()

    var chargerWatts: Double? { battery?.isPluggedIn == true ? powerUsage?.adapter : nil }   // delivered right now
    private var timer: Timer?

    func start() {
        refresh()
        if appleHealth == nil {   // ~0.06 s outside the app, once per window
            DispatchQueue.global(qos: .utility).async {
                let health = BatteryReader.appleHealth()
                DispatchQueue.main.async {
                    self.appleHealth = health
                    self.updateTips()
                }
            }
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Settings.shared.interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        battery = reader.read()
        temperature = temperatures.batteryTemperature()
        powerUsage = power.read()
        updateTips()
    }

    private func updateTips() {
        guard let battery else { tips = []; return }
        let busiest = battery.isPluggedIn ? nil : processes.top(1).first   // only matters on battery
        tips = BatteryTips.now(.init(
            battery: battery,
            temperature: temperature,
            power: powerUsage,
            healthPercent: appleHealth.flatMap { Int($0.maximumCapacity.filter(\.isNumber)) },
            busiestApp: busiest.map { ($0.name, $0.percent) },
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }

    /// System Settings → Battery.
    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct BatteryView: View {
    @ObservedObject var model: BatteryModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            if let battery = model.battery {
                Section { summary(battery) }

                Section(tr("Съвети за теб сега", "Tips for you right now")) {
                    ForEach(model.tips) { tip in
                        Label { Text(tip.text) } icon: { tipIcon(tip.kind) }
                    }
                    Button(tr("Отвори настройките на батерията…", "Open Battery settings…")) { model.openBatterySettings() }
                }

                Section(tr("Капацитет", "Capacity")) {
                    row(tr("Побира сега", "Holds now"), "\(battery.fullCapacity) mAh")
                    row(tr("Побираше като нова", "Held when new"), "\(battery.designCapacity) mAh")
                    row(tr("Остава от новото (по mAh)", "Left of new (by mAh)"), String(format: "%.0f%%", battery.capacityPercent))
                    row(tr("Заредена в момента", "Charge right now"), "\(battery.charge) mAh")
                    row(tr("Волтаж", "Voltage"), String(format: "%.2f V", battery.voltage))
                    row(tr("Мощност", "Power"), powerText(battery.watts))
                }

                if battery.isPluggedIn {
                    Section(tr("Зарядно", "Charger")) {
                        row(tr("Мощност на зарядното", "Charger rating"), battery.adapterWatts.map { "\($0) W" } ?? "–")
                        row(tr("Подава в момента", "Delivering now"), model.chargerWatts.map(watts) ?? "–")
                    }
                }

                Section(tr("Как да пазиш батерията", "How to look after the battery")) {
                    ForEach(BatteryTips.general, id: \.self) { tip in
                        Label { Text(tip) } icon: {
                            Image(systemName: "leaf").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(tr("„Здраве“ е числото от System Settings → Battery. Apple го смята по свой начин, затова може леко да се различава от сметката по mAh.",
                            "“Health” is the number from System Settings → Battery. Apple computes it its own way, so it can differ a little from the mAh math."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Summary

    private func summary(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(battery.percent)%").font(.system(size: 34, weight: .semibold))
                    Text(status(battery)).foregroundStyle(.secondary)
                }
                Spacer()
                tile(tr("Здраве", "Health"), model.appleHealth?.maximumCapacity ?? "…",
                     help: model.appleHealth.map { tr("Състояние: ", "Condition: ") + condition($0.condition) })
                tile(tr("Цикли", "Cycles"), battery.designCycles.map { "\(battery.cycles) / \($0)" } ?? "\(battery.cycles)",
                     help: tr("Батерията е предвидена за толкова цикъла", "The battery is rated for this many cycles"))
                tile(tr("Температура", "Temperature"), model.temperature.map(degrees) ?? "–", help: nil)
            }
            ChargeMeter(percent: battery.percent)
        }
        .padding(.vertical, 4)
    }

    private func status(_ battery: BatteryInfo) -> String {
        if battery.isCharging {
            return tr("Зарежда", "Charging") + (battery.minutesLeft.map { tr(" · пълна след ", " · full in ") + duration($0) } ?? "")
        }
        if battery.isPluggedIn {
            return battery.isFull ? tr("Заредена докрай", "Fully charged")
                                  : tr("На зарядно, на пауза: macOS пази батерията", "Plugged in, paused: macOS is protecting the battery")
        }
        return tr("На батерия", "On battery") + " · " + (battery.minutesLeft.map { tr("остават ", "") + duration($0) + tr("", " left") }
                                                           ?? tr("изчислява се…", "estimating…"))
    }

    private func tile(_ label: String, _ value: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .help(help ?? "")
    }

    /// The icon carries the meaning together with its color, so it never relies on color alone.
    @ViewBuilder
    private func tipIcon(_ kind: BatteryTip.Kind) -> some View {
        switch kind {
        case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func powerText(_ value: Double) -> String {
        if value > 0.1 { return tr("зарежда с ", "charging at ") + watts(value) }
        if value < -0.1 { return tr("дава ", "giving ") + watts(-value) }
        return tr("в покой", "idle")
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? tr("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min")
                      : tr("\(minutes) мин", "\(minutes) min")
    }

    private func condition(_ apple: String) -> String {
        switch apple {
        case "Good", "Normal": tr("добро", "good")
        case "Fair": tr("задоволително", "fair")
        case "Poor", "Service Recommended": tr("препоръчва се сервиз", "service recommended")
        default: apple
        }
    }
}

/// The charge as a meter: the fill on a lighter track of the same hue, so the level reads
/// against the full battery at a glance. Like macOS's own icon: orange below 20%, red below 10%.
private struct ChargeMeter: View {
    let percent: Int

    var body: some View {
        let color: Color = percent <= 10 ? .red : percent <= 20 ? .orange : .green
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: max(8, geo.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 8)
    }
}
