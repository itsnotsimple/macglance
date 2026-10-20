import SwiftUI

/// A chart section with the period picker (3 min … 7 days) above the chart.
/// The period is one setting for all charts, so switching pages keeps it.
struct HistoryPanel: View {
    let title: String
    let metric: Metric
    let maxValue: (([Sample]) -> Double)?   // nil = fixed 0...100 scale
    let format: (Double) -> String
    let showsPicker: Bool                    // off for a second chart right under the first
    @Binding var hoverIndex: Int?
    @ObservedObject private var settings = Settings.shared

    init(_ title: String, metric: Metric, maxValue: (([Sample]) -> Double)? = nil,
         format: @escaping (Double) -> String, showsPicker: Bool = true, hoverIndex: Binding<Int?>) {
        self.title = title
        self.metric = metric
        self.maxValue = maxValue
        self.format = format
        self.showsPicker = showsPicker
        self._hoverIndex = hoverIndex
    }

    var body: some View {
        let samples = MetricStore.shared.samples(metric, in: settings.chartRange)
        Section {
            HistoryChart(samples: samples, range: settings.chartRange, maxValue: maxValue?(samples) ?? 100,
                         format: format, apps: metric.appHistoryKind, hoverIndex: $hoverIndex)
                .frame(height: 150)
                .padding(.vertical, 4)
        } header: {
            HStack {
                Text(title)
                Spacer()
                if showsPicker {
                    Picker("", selection: $settings.chartRange) {
                        ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

/// One value over time: a line with a light wash under it, newest on the right edge ("now").
/// The scale is fixed per chart so it doesn't jump. Gaps (Mac asleep, app closed) break the line.
/// Hover shows the exact value, when it was, and which apps used the most then.
struct HistoryChart: View {
    let samples: [Sample]
    let range: TimeRange
    let maxValue: Double
    let format: (Double) -> String
    let apps: AppHistory.Kind?
    @Binding var hoverIndex: Int?

    private let axisWidth: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            // room above the top line for the hover label, below the plot for the time labels
            let plot = CGRect(x: axisWidth, y: 26, width: geo.size.width - axisWidth, height: geo.size.height - 46)
            let now = Date().timeIntervalSince1970
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(context, plot)
                    drawSeries(context, plot, now: now)
                    drawHover(context, plot, now: now)
                }
                ForEach([maxValue, maxValue / 2, 0], id: \.self) { mark in
                    Text(mark == 0 ? "0" : format(mark))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .position(x: axisWidth / 2 - 2, y: y(mark, plot))
                }
                Text(tr("преди ", "") + range.label + tr("", " ago"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .position(x: plot.minX + 34, y: plot.maxY + 12)
                Text(tr("сега", "now"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .position(x: plot.maxX - 12, y: plot.maxY + 12)
                if samples.isEmpty {
                    Text(tr("Още няма данни за този период", "No data for this period yet"))
                        .font(.callout).foregroundStyle(.secondary)
                        .position(x: plot.midX, y: plot.midY)
                }
                if let index = hoverIndex, samples.indices.contains(index) {
                    let who = whoUsed(index)
                    let halfWidth: CGFloat = who.isEmpty ? 70 : 150
                    tooltip(index, who: who, now: now)
                        .position(x: min(max(x(samples[index].time, plot, now), plot.minX + halfWidth), plot.maxX - halfWidth),
                                  y: who.isEmpty ? 10 : 14)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverIndex = nearestIndex(to: point.x, plot, now: now)
                case .ended: hoverIndex = nil
                }
            }
        }
    }

    private func x(_ time: TimeInterval, _ plot: CGRect, _ now: TimeInterval) -> CGFloat {
        plot.maxX - CGFloat((now - time) / range.seconds) * plot.width
    }

    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(min(max(value, 0), maxValue) / maxValue) * plot.height
    }

    private func nearestIndex(to pointX: CGFloat, _ plot: CGRect, now: TimeInterval) -> Int? {
        guard !samples.isEmpty, pointX >= plot.minX else { return nil }
        let time = now - Double((plot.maxX - pointX) / plot.width) * range.seconds
        return samples.indices.min { abs(samples[$0].time - time) < abs(samples[$1].time - time) }
    }

    /// A gap much longer than the usual spacing means no data (asleep, app closed): don't draw across it.
    private var gapLimit: TimeInterval {
        guard samples.count > 2 else { return .infinity }
        let steps = zip(samples.dropFirst(), samples).map { $0.time - $1.time }.sorted()
        return max(steps[steps.count / 2] * 4, 10)
    }

    private func drawGrid(_ context: GraphicsContext, _ plot: CGRect) {
        for mark in [0, maxValue / 2, maxValue] {   // solid hairlines, one step off the surface
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(mark, plot)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(mark, plot)))
            context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
    }

    private func drawSeries(_ context: GraphicsContext, _ plot: CGRect, now: TimeInterval) {
        // Split into runs at the gaps; each run gets its own line and wash.
        var runs: [[CGPoint]] = []
        var previousTime: TimeInterval?
        let limit = gapLimit
        for sample in samples {
            let point = CGPoint(x: x(sample.time, plot, now), y: y(sample.value, plot))
            if let previousTime, sample.time - previousTime <= limit { runs[runs.count - 1].append(point) } else { runs.append([point]) }
            previousTime = sample.time
        }
        for run in runs where run.count > 1 {
            var line = Path()
            line.addLines(run)
            var area = line
            area.addLine(to: CGPoint(x: run.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: run.first!.x, y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .color(.blue.opacity(0.1)))
            context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawHover(_ context: GraphicsContext, _ plot: CGRect, now: TimeInterval) {
        guard let index = hoverIndex, samples.indices.contains(index) else { return }
        let point = CGPoint(x: x(samples[index].time, plot, now), y: y(samples[index].value, plot))
        var rule = Path()
        rule.move(to: CGPoint(x: point.x, y: plot.minY))
        rule.addLine(to: CGPoint(x: point.x, y: plot.maxY))
        context.stroke(rule, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        // 8 pt dot with a 2 pt ring in the surface color, so it stays readable on the line
        let ring = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        context.fill(Path(ellipseIn: ring), with: .color(Color(nsColor: .controlBackgroundColor)))
        context.fill(Path(ellipseIn: ring.insetBy(dx: 2, dy: 2)), with: .color(.blue))
    }

    /// "37% · преди 12 s" for short periods, "37% · 14:32" (or "Mon 14:32" over 7 days) for long ones,
    /// with who used the most under it.
    private func tooltip(_ index: Int, who: String, now: TimeInterval) -> some View {
        let sample = samples[index]
        let secondsAgo = Int(now - sample.time)
        let when: String
        if range == .minutes3 {
            when = secondsAgo < 3 ? tr("сега", "now") : tr("преди \(secondsAgo) s", "\(secondsAgo) s ago")
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: Settings.shared.language == .bg ? "bg_BG" : "en_US")
            formatter.dateFormat = range == .days7 ? "EEE HH:mm" : "HH:mm"
            when = formatter.string(from: Date(timeIntervalSince1970: sample.time))
        }
        return VStack(spacing: 1) {
            Text(format(sample.value) + " · " + when)
                .font(.caption)
            if !who.isEmpty {
                Text(who)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: who.isEmpty ? 10 : 8))
    }

    /// "Safari 30% · Code 8%": the apps that used the most around this point (the stretch halfway to its
    /// neighbours, at least a minute). Not on the 3-minute chart: apps are kept per minute.
    /// Where there's nothing yet, it says why instead of showing nothing.
    private func whoUsed(_ index: Int) -> String {
        guard let apps, range != .minutes3 else { return "" }
        let time = samples[index].time
        let before = index > 0 ? (samples[index - 1].time + time) / 2 : time
        let after = index + 1 < samples.count ? (time + samples[index + 1].time) / 2 : time
        let names = AppHistory.shared.top(apps, from: min(before, time - 30), to: max(after, time + 30))
            .compactMap { app -> String? in
                let value: String
                switch apps {
                case .cpu, .gpu:
                    guard app.value >= 0.1 else { return nil }
                    value = String(format: app.value < 10 ? "%.1f%%" : "%.0f%%", app.value)
                case .power:
                    guard app.value >= 0.05 else { return nil }
                    value = watts(app.value)
                case .down, .up:
                    guard app.value >= 1000 else { return nil }
                    value = speedText(app.value)
                }
                return app.name + " " + value
            }
            .joined(separator: " · ")
        guard names.isEmpty else { return names }
        guard let covered = AppHistory.shared.covered(apps), time < covered.upperBound else {
            return tr("Кой е бил: след минута", "Who: in a minute")   // the newest minute is stored when it ends
        }
        if time < covered.lowerBound {
            let start = Date(timeIntervalSince1970: covered.lowerBound)
            let format = DateFormatter()
            format.dateFormat = Calendar.current.isDateInToday(start) ? "HH:mm" : "d.MM HH:mm"
            return tr("Кой е бил: записва се от ", "Who: recorded since ") + format.string(from: start)
        }
        return ""   // asleep then, or nothing worth naming
    }
}
