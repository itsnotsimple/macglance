import AppKit
import SwiftUI

/// Live data for the Energy page: watts right now, energy per period and per day.
/// Refreshes only while the page is on screen.
final class EnergyModel: ObservableObject {
    @Published private(set) var power: PowerUsage?
    @Published var hoverIndex: Int?
    @Published var dayHover: Int?                                    // daily column under the mouse
    @Published private(set) var recentDays: [(date: Date, day: EnergyLedger.Day?)] = []   // last 14, oldest first
    private let powerReader = PowerReader()
    private var timer: Timer?

    /// The price as typed. Only digits and one decimal point (or comma) get through.
    @Published var priceText: String = {
        let price = Settings.shared.electricityPrice
        return price > 0 ? String(format: "%g", price) : ""
    }() {
        didSet {
            let filtered = Self.priceCharacters(priceText)
            guard filtered == priceText else { priceText = filtered; return }   // runs didSet again, cleaned
            Settings.shared.electricityPrice = Double(filtered.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
    }

    private static func priceCharacters(_ text: String) -> String {
        var result = ""
        var hasSeparator = false
        for character in text {
            if character.isASCII, character.isNumber {
                result.append(character)
            } else if (character == "." || character == ","), !hasSeparator {
                result.append(character)
                hasSeparator = true
            }
        }
        return String(result.prefix(8))
    }


    func start() {
        refresh()   // baseline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }   // first numbers fast
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Settings.shared.interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        power = powerReader.read()
        let ledger = EnergyLedger.shared
        recentDays = (0..<14).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            return (date, ledger.day(date))
        }
    }

    var today: EnergyLedger.Day? { recentDays.last?.day }

    /// From the wall this calendar month.
    var monthWallWh: Double {
        let month = Calendar.current.component(.month, from: Date())
        return EnergyLedger.shared.days
            .filter { Int($0.key.dropFirst(5).prefix(2)) == month && $0.key.hasPrefix(String(Calendar.current.component(.year, from: Date()))) }
            .map(\.value.wallWh).reduce(0, +)
    }

    /// A 30-day estimate from the average of the full days we have (up to the last 7). Nil with fewer than 2.
    var monthEstimateWh: Double? {
        let fullDays = recentDays.dropLast().suffix(7).compactMap(\.day).filter { $0.wallWh > 0 || $0.usedWh > 0 }
        guard fullDays.count >= 2 else { return nil }
        return fullDays.map(\.wallWh).reduce(0, +) / Double(fullDays.count) * 30
    }

    /// Asks the app to quit, like ⌘Q: it may still ask to save your work.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }
}

struct EnergyView: View {
    @ObservedObject var model: EnergyModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section { summary }

            HistoryPanel(tr("Цялата система", "Whole system"), metric: .power, maxValue: Self.scaleTop,
                         format: { String(format: "%.0f W", $0) }, hoverIndex: $model.hoverIndex)

            periodSection

            billSection
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }


    /// The scale steps up only when needed (10, 20, 40… W), so the chart rarely jumps.
    private static func scaleTop(_ samples: [Sample]) -> Double {
        let peak = samples.map(\.value).max() ?? 0
        return [10.0, 20, 40, 60, 100, 150, 200].first { $0 >= peak * 1.1 } ?? 300
    }


    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.power.map { watts($0.system) } ?? "–")
                    .font(.system(size: 34, weight: .semibold))
                Text(tr("Цялата система", "Whole system")).foregroundStyle(.secondary)
            }
            Spacer()
            tile("CPU", model.power.map { watts($0.cpu) })
            tile("GPU", model.power.map { watts($0.gpu) })
            tile(tr("Екран и др.", "Screen etc."), model.power.map { watts($0.other) })
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–").font(.title3.weight(.semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

}

/// A thin bar for one row's share of the total: one hue, rounded at the data end only.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.blue.opacity(0.15))
            UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                .fill(.blue)
                .frame(width: max(2, 56 * share))
        }
        .frame(width: 56, height: 6)
    }
}

// MARK: - Electricity bill

extension EnergyView {
    var billSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                billTile(tr("Днес", "Today"), model.today?.wallWh ?? 0)
                billTile(tr("Този месец", "This month"), model.monthWallWh)
                if let estimate = model.monthEstimateWh {
                    billTile(tr("Прогноза за месец", "Month estimate"), estimate)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("–").font(.title3.weight(.semibold))
                        Text(tr("Прогноза след 2 дни", "Estimate after 2 days")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)

            DailyBars(days: model.recentDays, hover: $model.dayHover)
                .frame(height: 130)
                .padding(.vertical, 4)

            HStack {
                Text(tr("Цена на kWh", "Price per kWh"))
                Spacer()
                TextField("0.15", text: $model.priceText)
                    .labelsHidden()   // in a Form the placeholder would also show up as a label
                    .textFieldStyle(.roundedBorder)   // looks like an input box, with a focus ring when clicked
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                TextField("€", text: Binding(get: { settings.currency },
                                             set: { settings.currency = String($0.prefix(3)) }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
            }
        } header: {
            Text(tr("Консумация и сметка", "Usage and bill"))
        } footer: {
            Text(settings.electricityPrice > 0
                 ? tr("Сметката брои това, което Макът тегли от контакта (с зареждането на батерията), без ~10% загуби в самото зарядно. Брои се, докато MacGlance работи; в sleep Макът почти не харчи.",
                      "The bill counts what the Mac draws from the wall (including charging the battery), without the ~10% lost in the charger itself. It counts while MacGlance runs; asleep, the Mac uses next to nothing.")
                 : tr("Въведи цената на kWh от сметката си, за да видиш колко струва.",
                      "Enter the price per kWh from your bill to see what it costs."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Who used how much energy over the period picked above the chart.
    var periodSection: some View {
        let usage = EnergyLedger.shared.usage(settings.chartRange)
        let appsTotal = usage.apps.map(\.app.wh).reduce(0, +)
        let shown = usage.apps.filter { $0.app.wh >= 0.005 }.prefix(10)   // below that it would read 0.00 Wh
        return Section {
            if shown.isEmpty {
                Text(tr("Събира се… (обновява се веднъж на минута)", "Collecting… (updates once a minute)"))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(shown), id: \.key) { entry in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.key).first
                HStack(spacing: 10) {
                    appIcon(entry.key)
                    Text(entry.app.name).lineLimit(1)
                    Spacer()
                    ShareBar(share: usage.usedWh > 0 ? entry.app.wh / usage.usedWh : 0)
                    energyCell(entry.app.wh)
                    QuitSlot(app: running, canQuit: running.map(isQuittable) ?? false, quit: model.quit)
                }
            }
            if !shown.isEmpty {
                let rest = max(0, usage.usedWh - appsTotal)
                HStack(spacing: 10) {
                    Image(systemName: "display")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                    Text(tr("Екран и системата", "Screen and system")).lineLimit(1)
                    Spacer()
                    ShareBar(share: usage.usedWh > 0 ? rest / usage.usedWh : 0)
                    energyCell(rest)
                    QuitSlot(app: nil, canQuit: false, quit: { _ in })
                }
            }
        } header: {
            Text(tr("Кой колко изхарчи · последните ", "Who used what · last ") + settings.chartRange.label)
        } footer: {
            Text(tr("Периодът е този, избран над графиката. CPU частта е измерена от macOS за всеки процес; видеокартата се дели според това кой колко време я ползва. Лентата е делът от цялата консумация за периода.",
                    "The period is the one picked above the chart. The CPU part is measured by macOS for every process; the GPU is split by how much GPU time each app uses. The bar is the share of all energy in the period."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func energyCell(_ wattHours: Double) -> some View {
        Text(energyText(wattHours) + (costText(wattHours).map { " · " + $0 } ?? ""))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 124, alignment: .trailing)
    }

    private func appIcon(_ key: String) -> some View {
        AppIconView(image: AppIcons.small(bundleID: key))
    }

    private func billTile(_ label: String, _ wattHours: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(costText(wattHours) ?? energyText(wattHours)).font(.title3.weight(.semibold))
            Text(label + (costText(wattHours) != nil ? " · " + energyText(wattHours) : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// One column per day (from the wall), today in full blue and earlier days lighter, so today
/// stands out. Hover shows the date, energy and cost.
private struct DailyBars: View {
    let days: [(date: Date, day: EnergyLedger.Day?)]
    @Binding var hover: Int?

    var body: some View {
        GeometryReader { geo in
            let values = days.map { $0.day?.wallWh ?? 0 }
            let top = max(values.max() ?? 0, 1)
            let slot = geo.size.width / CGFloat(max(days.count, 1))
            let barWidth = min(24, slot - 6)
            let plotHeight = geo.size.height - 40
            ZStack(alignment: .topLeading) {
                ForEach(days.indices, id: \.self) { index in
                    let height = max(2, plotHeight * CGFloat(values[index] / top))
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)   // square at the baseline
                        .fill(index == days.count - 1 ? Color.blue : Color.blue.opacity(0.4))
                        .frame(width: barWidth, height: height)
                        .position(x: slot * (CGFloat(index) + 0.5), y: 24 + plotHeight - height / 2)
                    Text(index == days.count - 1 ? tr("днес", "today") : dayNumber(days[index].date))
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x: slot * (CGFloat(index) + 0.5), y: geo.size.height - 8)
                }
                if let index = hover, days.indices.contains(index) {
                    tooltip(index, values[index])
                        .position(x: min(max(slot * (CGFloat(index) + 0.5), 90), geo.size.width - 90), y: 9)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(max(Int(point.x / slot), 0), days.count - 1)
                case .ended: hover = nil
                }
            }
        }
    }

    private func dayNumber(_ date: Date) -> String { "\(Calendar.current.component(.day, from: date))" }

    private func tooltip(_ index: Int, _ wattHours: Double) -> some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Settings.shared.language == .bg ? "bg_BG" : "en_US")
        formatter.dateFormat = "EEE d.MM"
        let cost = costText(wattHours).map { " · " + $0 } ?? ""
        return Text(formatter.string(from: days[index].date) + " · " + energyText(wattHours) + cost)
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }
}
