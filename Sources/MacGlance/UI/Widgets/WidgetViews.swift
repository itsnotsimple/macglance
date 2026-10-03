import SwiftUI

/// One desktop widget: a rounded glass card with a title, one big number, a few details,
/// and a sparkline of the last 3 minutes (or a meter, for RAM and battery).
/// The wide size puts a larger chart on the right.
struct WidgetCard: View {
    let kind: WidgetKind
    let size: WidgetSize
    @ObservedObject var data: WidgetData
    @ObservedObject var widgets: DesktopWidgets
    @ObservedObject private var settings = Settings.shared   // redraws on a language change

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(kind.title, systemImage: kind.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(headline)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ForEach(details, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if size == .small { footer }
            }
            .frame(width: 130, alignment: .leading)
            if size == .wide {
                VStack(alignment: .leading, spacing: 6) {
                    footer
                    ForEach(wideDetails, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: size.points.width, height: size.points.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            ForEach(WidgetSize.allCases, id: \.self) { option in
                Button((option == size ? "✓ " : "") + option.title) { widgets.setSize(kind, option) }
            }
            Divider()
            Button(tr("Махни уиджета", "Remove widget")) { widgets.setOn(kind, false) }
            Button(tr("Отвори MacGlance", "Open MacGlance")) { widgets.openApp() }
        }
    }

    // MARK: - What each kind shows

    private var headline: String {
        switch kind {
        case .cpu: data.cpu.map { String(format: "%.0f%%", $0.total) } ?? "–"
        case .gpu: data.gpu.map { "\($0.load)%" } ?? "–"
        case .ram: data.memory.map { memoryText($0.used) } ?? "–"
        case .power: data.power.map { watts($0.system) } ?? "–"
        case .network: data.network.map { "↓ " + speedText($0.downPerSecond) } ?? "–"
        case .temperature: data.temperatures?.cpu.map(degrees) ?? "–"
        case .battery: data.battery.map { "\($0.percent)%" } ?? "–"
        }
    }

    private var details: [String] {
        switch kind {
        case .cpu:
            guard let load = data.cpu, CPUReader.coreKinds.count == load.cores.count else { return [] }
            func average(_ kind: CoreKind) -> Double {
                let values = zip(load.cores, CPUReader.coreKinds).filter { $0.1 == kind }.map(\.0)
                return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
            return [String(format: "P %.0f%% · E %.0f%%", average(.performance), average(.efficiency))]
        case .gpu:
            return [data.power.map { watts($0.gpu) }, data.gpu?.memoryInUse.map(memoryText)].compactMap { $0 }
        case .ram:
            guard let memory = data.memory else { return [] }
            return [tr("от ", "of ") + memoryText(memory.total) + String(format: " · %.0f%%", memory.usedPercent)]
        case .power:
            guard let power = data.power else { return [] }
            return ["CPU " + watts(power.cpu) + " · GPU " + watts(power.gpu)]
        case .network:
            return [data.network.map { "↑ " + speedText($0.upPerSecond) }].compactMap { $0 }
        case .temperature:
            guard let temps = data.temperatures else { return [] }
            return [[temps.gpuMax.map { "GPU " + degrees($0) }, temps.ssd.map { "SSD " + degrees($0) }].compactMap { $0 }
                .joined(separator: " · ")]
        case .battery:
            guard let battery = data.battery else { return [] }
            if battery.isCharging { return [tr("зарежда", "charging")] }
            if battery.isPluggedIn { return [tr("на зарядно", "plugged in")] }
            return [battery.minutesLeft.map { tr("остават ", "") + duration($0) + tr("", " left") } ?? tr("на батерия", "on battery")]
        }
    }

    /// Extra lines the wide size has room for, under its chart.
    private var wideDetails: [String] {
        switch kind {
        case .network: [tr("Днес: ", "Today: ") + bytesText(DailyTraffic.shared.down + DailyTraffic.shared.up)]
        case .battery: data.battery.map { [tr("\($0.cycles) цикъла", "\($0.cycles) cycles") + " · " + watts(abs($0.watts))] } ?? []
        case .ram: data.memory.map { ["Swap " + memoryText($0.swap)] } ?? []
        default: []
        }
    }

    /// A sparkline for the kinds that have history, a meter for the rest.
    @ViewBuilder
    private var footer: some View {
        switch kind {
        case .ram:
            Meter(fraction: data.memory.map { $0.usedPercent / 100 } ?? 0, color: pressureColor)
        case .battery:
            let percent = data.battery?.percent ?? 0
            Meter(fraction: Double(percent) / 100, color: percent <= 10 ? .red : percent <= 20 ? .orange : .green)
        default:
            Sparkline(samples: MetricStore.shared.samples(metric, in: .minutes3, maxPoints: 60), maxValue: sparkMax)
                .frame(height: size == .wide ? 92 : 34)
        }
    }

    private var metric: Metric {
        switch kind {
        case .gpu: .gpu
        case .power: .power
        case .network: .networkDown
        case .temperature: .cpuTemperature
        default: .cpu
        }
    }

    /// Load is out of 100%; the rest scale to their own peak so the line uses the height.
    private var sparkMax: Double? {
        kind == .cpu || kind == .gpu ? 100 : (kind == .temperature ? 110 : nil)
    }

    private var pressureColor: Color {
        switch data.memory?.pressure {
        case .warning: .yellow
        case .critical: .red
        default: .green
        }
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? tr("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min")
                      : tr("\(minutes) мин", "\(minutes) min")
    }
}

/// A line with a light wash under it; no axes, it only shows the shape of the last minutes.
private struct Sparkline: View {
    let samples: [Sample]
    let maxValue: Double?   // nil = scale to the peak

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let top = maxValue ?? max(samples.map(\.value).max() ?? 1, 0.001) * 1.15
            let first = samples.first!.time, span = max(samples.last!.time - first, 1)
            let points = samples.map { sample in
                CGPoint(x: CGFloat((sample.time - first) / span) * size.width,
                        y: size.height - CGFloat(min(sample.value / top, 1)) * size.height)
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.blue.opacity(0.15)))
            context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A share of a whole: the fill on a lighter track of the same color.
private struct Meter: View {
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
