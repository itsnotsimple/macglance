import SwiftUI

/// Live data for the Temperatures page. Reads only while the page is on screen (the chart comes from MetricStore).
final class TemperatureModel: ObservableObject {
    @Published private(set) var temps: Temperatures?
    @Published private(set) var thermal: ThermalStatus?
    @Published var hoverIndex: Int?
    private let reader = TemperatureReader()
    private let thermalReader = ThermalReader()
    private var timer: Timer?

    func start() {
        refresh()
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
        temps = reader.read()
        let status = thermalReader.read()
        if status.frequencies != nil || thermal == nil { thermal = status }   // keep speeds while a new baseline is taken
    }
}

struct TemperatureView: View {
    @ObservedObject var model: TemperatureModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            if let temps = model.temps {
                Section { summary(temps) }
            }

            if let thermal = model.thermal {
                Section {
                    Label {
                        Text(thermal.summary.text)
                    } icon: {
                        Image(systemName: thermal.summary.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(thermal.summary.warning ? .orange : .green)
                    }
                    if let speeds = thermal.frequencies {
                        speedRow(tr("P-ядра работят на", "P-cores running at"), speeds.pMHz, of: speeds.pMaxMHz)
                        speedRow(tr("E-ядра работят на", "E-cores running at"), speeds.eMHz, of: speeds.eMaxMHz)
                    }
                } header: {
                    Text(tr("Термично забавяне", "Thermal throttling"))
                } footer: {
                    Text(tr("При лека работа честотите нарочно са ниски, за да пестят енергия: това не е забавяне. Забавяне има, когато горе не пише „Няма забавяне“. В тест с всички 10 ядра на пълна мощност този Мак държа максимума поне 90 секунди (до 90°C).",
                            "During light work the speeds are low on purpose to save energy: that's not throttling. It is throttling when the line above doesn't say \"No slowdown\". In a test with all 10 cores at full power, this Mac held top speed for at least 90 seconds (up to 90°C)."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HistoryPanel(tr("История на CPU", "CPU history"), metric: .cpuTemperature,
                         maxValue: { _ in 120 }, format: degrees, hoverIndex: $model.hoverIndex)

            if let temps = model.temps {
                Section {
                    row(tr("P-ядра", "P-cores"), temps.pCores)
                    row(tr("E-ядра", "E-cores"), temps.eCores)
                    row("GPU", temps.gpu)
                    single("SSD", temps.ssd)
                    single(tr("Батерия", "Battery"), temps.battery)
                } header: {
                    Text(tr("Сензори", "Sensors"))
                } footer: {
                    Text(tr("Apple Silicon работи нормално до около 100–105°C под натоварване. Над това macOS забавя процесора, за да го охлади. Показва се най-горещата точка, защото тя решава кога ще се забави.",
                            "Apple Silicon runs normally up to about 100–105°C under load. Above that, macOS slows the chip down to cool it. The hottest spot is shown because it decides when that happens."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func summary(_ temps: Temperatures) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(temps.cpu.map(degrees) ?? "–")
                    .font(.system(size: 34, weight: .semibold))
                Text(tr("CPU, най-горещата точка", "CPU, hottest spot")).foregroundStyle(.secondary)
            }
            Spacer()
            tile("GPU", temps.gpuMax)
            tile("SSD", temps.ssd)
            tile(tr("Батерия", "Battery"), temps.battery)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(degrees) ?? "–").font(.title3.weight(.semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// A group of sensors: how many, the average and the hottest one.
    private func row(_ label: String, _ values: [Double]) -> some View {
        HStack {
            Text(label)
            Text(tr("\(values.count) сензора", "\(values.count) sensors")).foregroundStyle(.secondary)
            Spacer()
            if let hottest = values.max() {
                Text(tr("средно ", "avg ") + degrees(values.reduce(0, +) / Double(values.count)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(tr("макс. ", "max ") + degrees(hottest))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .trailing)
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
    }

    /// "3.85 GHz of 4.46", with a meter for how close to top speed.
    private func speedRow(_ label: String, _ mhz: Double, of maximum: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.blue.opacity(0.15))
                    Capsule().fill(.blue).frame(width: max(4, geo.size.width * CGFloat(min(mhz / max(maximum, 1), 1))))
                }
            }
            .frame(width: 90, height: 6)
            Text(mhz > 0 ? String(format: tr("%.2f от %.2f GHz", "%.2f of %.2f GHz"), mhz / 1000, maximum / 1000)
                         : tr("почиват", "resting"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 130, alignment: .trailing)
        }
    }

    private func single(_ label: String, _ value: Double?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.map(degrees) ?? "–")
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}
