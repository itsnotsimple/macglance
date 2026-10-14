import Shared
import SwiftUI
import WidgetKit

// MARK: - Language

/// The same text in both languages; the widget follows the language set in MacGlance.
struct Words {
    let bg: String
    let en: String
    init(_ bg: String, _ en: String) { self.bg = bg; self.en = en }
    func callAsFunction(_ language: String) -> String { language == "bg" ? bg : en }
}

/// Before MacGlance has written anything: Bulgarian if it's in the Mac's language list, like the app.
var currentLanguage: String {
    WidgetShared.load()?.language ?? (Locale.preferredLanguages.contains { $0.hasPrefix("bg") } ? "bg" : "en")
}

extension Text {
    static func localized(_ words: Words) -> Text { Text(words(currentLanguage)) }
}

extension Kind {
    var title: Words {
        switch self {
        case .cpu: Words("CPU", "CPU")
        case .gpu: Words("GPU", "GPU")
        case .ram: Words("RAM", "RAM")
        case .power: Words("Мощност", "Power")
        case .network: Words("Мрежа", "Network")
        case .temperature: Words("Температура", "Temperature")
        case .battery: Words("Батерия", "Battery")
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.grid.3x3.square"
        case .ram: "memorychip"
        case .power: "bolt"
        case .network: "wifi"
        case .temperature: "thermometer.medium"
        case .battery: "battery.75percent"
        }
    }

    /// The history line it draws, if any.
    var history: String? {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .power: "power"
        case .network: "networkDown"
        case .temperature: "cpuTemperature"
        case .ram, .battery: nil
        }
    }
}

// MARK: - One metric

struct MetricView: View {
    let kind: Kind
    let entry: Entry
    var previewFamily: WidgetFamily? = nil   // for README screenshots; macOS sets the real one
    @Environment(\.widgetFamily) private var hostFamily
    private var family: WidgetFamily { previewFamily ?? hostFamily }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, isFresh(snapshot) {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 16) {
                        summary(snapshot).frame(width: 128, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            footer(snapshot, height: 70)
                            ForEach(extra(snapshot), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        summary(snapshot)
                        Spacer(minLength: 4)
                        footer(snapshot, height: 30)
                    }
                }
            } else {
                NotRunning(snapshot: entry.snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // fill the widget, so charts get its width
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func summary(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(kind.title(s.language), systemImage: kind.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(s.time, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(headline(s))
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            ForEach(details(s), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func headline(_ s: WidgetSnapshot) -> String {
        switch kind {
        case .cpu: s.cpu.map(percent) ?? "–"
        case .gpu: s.gpu.map(percent) ?? "–"
        case .ram: s.ramUsed.map(memoryText) ?? "–"
        case .power: s.watts.map(watts) ?? "–"
        case .network: s.down.map { "↓ " + speedText($0) } ?? "–"
        case .temperature: s.cpuTemperature.map(degrees) ?? "–"
        case .battery: s.battery.map { "\($0)%" } ?? "–"
        }
    }

    private func details(_ s: WidgetSnapshot) -> [String] {
        let w = s.language
        switch kind {
        case .cpu:
            guard let p = s.pCores, let e = s.eCores else { return [] }
            return ["P " + percent(p) + " · E " + percent(e)]
        case .gpu:
            return [s.gpuWatts.map(watts), s.gpuMemory.map(memoryText)].compactMap { $0 }
        case .ram:
            guard let used = s.ramUsed, let total = s.ramTotal else { return [] }
            return [Words("от ", "of ")(w) + memoryText(total) + " · " + percent(used / total * 100)]
        case .power:
            return [s.cpuWatts.map { "CPU " + watts($0) }].compactMap { $0 }
        case .network:
            return [s.up.map { "↑ " + speedText($0) }].compactMap { $0 }
        case .temperature:
            return [[s.gpuTemperature.map { "GPU " + degrees($0) }, s.ssdTemperature.map { "SSD " + degrees($0) }]
                .compactMap { $0 }.joined(separator: " · ")]
        case .battery:
            if s.charging == true { return [Words("зарежда", "charging")(w)] }
            if s.pluggedIn == true { return [Words("на зарядно", "plugged in")(w)] }
            return [s.minutesLeft.map { Words("остават ", "")(w) + duration($0, w) + Words("", " left")(w) } ?? Words("на батерия", "on battery")(w)]
        }
    }

    /// Extra lines the medium size has room for.
    private func extra(_ s: WidgetSnapshot) -> [String] {
        let w = s.language
        switch kind {
        case .network: return [s.todayTraffic.map { Words("Днес: ", "Today: ")(w) + bytesText($0) }].compactMap { $0 }
        case .ram: return [s.swap.map { "Swap " + memoryText($0) }].compactMap { $0 }
        case .battery: return [s.cycles.map { Words("\($0) цикъла", "\($0) cycles")(w) }].compactMap { $0 }
        default: return [Words("последния час", "the last hour")(w)]
        }
    }

    @ViewBuilder
    private func footer(_ s: WidgetSnapshot, height: CGFloat) -> some View {
        switch kind {
        case .ram:
            let fraction = (s.ramUsed ?? 0) / max(s.ramTotal ?? 1, 1)
            Meter(fraction: fraction, color: s.ramPressure == 4 ? .red : s.ramPressure == 2 ? .yellow : .green)
        case .battery:
            let level = s.battery ?? 0
            Meter(fraction: Double(level) / 100, color: level <= 10 ? .red : level <= 20 ? .orange : .green)
        default:
            Sparkline(values: kind.history.flatMap { s.history[$0] } ?? [],
                      top: kind == .cpu || kind == .gpu ? 100 : kind == .temperature ? 110 : nil)
                .frame(height: height)
        }
    }
}

// MARK: - Everything at once

struct OverviewView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot, isFresh(s) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("MacGlance").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(s.time, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            tile("CPU", s.cpu.map(percent))
                            tile("GPU", s.gpu.map(percent))
                            tile("RAM", s.ramUsed.flatMap { used in s.ramTotal.map { percent(used / $0 * 100) } })
                        }
                        GridRow {
                            tile(Words("Ватове", "Watts")(s.language), s.watts.map(watts))
                            tile(Words("Сваляне", "Download")(s.language), s.down.map(speedText))
                            tile(Words("Темп.", "Temp.")(s.language), s.cpuTemperature.map(degrees))
                        }
                    }
                    if family == .systemLarge {
                        chart("CPU", s.history["cpu"] ?? [], top: 100)
                        chart(Words("Ватове", "Watts")(s.language), s.history["power"] ?? [], top: nil)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                NotRunning(snapshot: entry.snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func tile(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value ?? "–").font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func chart(_ label: String, _ values: [Double], top: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Sparkline(values: values, top: top).frame(height: 54)
        }
    }
}

/// Shown when MacGlance isn't running (or hasn't written anything for a while).
struct NotRunning: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        let w = snapshot?.language ?? currentLanguage
        VStack(alignment: .leading, spacing: 4) {
            Label("MacGlance", systemImage: "cpu").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(Words("Пусни MacGlance, за да се обновява.", "Open MacGlance to keep this updated.")(w))
                .font(.callout)
            if let time = snapshot?.time {
                Text(Words("Последно: ", "Last update: ")(w) + time.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Older than 15 minutes: MacGlance has probably stopped.
func isFresh(_ s: WidgetSnapshot) -> Bool { Date().timeIntervalSince(s.time) < 900 }

// MARK: - Drawing

/// A line with a light wash under it: only the shape of the last hour, no axes.
struct Sparkline: View {
    let values: [Double]
    let top: Double?   // nil = scale to the peak

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let ceiling = top ?? max(values.max() ?? 1, 0.001) * 1.15
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height - CGFloat(min(max(value, 0) / ceiling, 1)) * size.height)
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.blue.opacity(0.15)))
            context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A share of a whole: the fill on a lighter track of the same color.
struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.2))
                Capsule().fill(color).frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Formatting (the same rules as in the app)

func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
func watts(_ value: Double) -> String { String(format: value < 1 ? "%.2f W" : "%.1f W", value) }
func degrees(_ value: Double) -> String { String(format: "%.0f°", value) }
func memoryText(_ bytes: Double) -> String {
    bytes < 1_073_741_824 ? String(format: "%.0f MB", bytes / 1_048_576) : String(format: "%.1f GB", bytes / 1_073_741_824)
}
func speedText(_ bytesPerSecond: Double) -> String {
    bytesPerSecond < 1e6 ? String(format: "%.0f KB/s", bytesPerSecond / 1e3) : String(format: "%.1f MB/s", bytesPerSecond / 1e6)
}
func bytesText(_ bytes: Double) -> String {
    bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
}
func duration(_ minutes: Int, _ language: String) -> String {
    minutes >= 60 ? Words("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min")(language)
                  : Words("\(minutes) мин", "\(minutes) min")(language)
}
