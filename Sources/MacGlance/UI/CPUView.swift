import AppKit
import CSensors
import SwiftUI

/// Live data for the CPU page. Refreshes only while the page is on screen.
final class CPUModel: ObservableObject {
    @Published private(set) var load: CPULoad?
    @Published private(set) var power: PowerUsage?
    @Published private(set) var processes: [ProcessCPU] = []
    @Published var hoverIndex: Int?   // history sample under the mouse
    @Published var coreHover: Int?    // core under the mouse (kernel's numbering)
    @Published private(set) var temperatures: Temperatures?
    @Published private(set) var speeds: CPUFrequencies?
    private let cpu = CPUReader()
    private let temperatureReader = TemperatureReader()
    private let thermal = ThermalReader()
    private let powerReader = PowerReader()
    private let processReader = ProcessCPUReader()
    private var timer: Timer?

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

    private var refreshes = 0

    func refresh(force: Bool = false) {
        refreshes += 1
        load = cpu.read() ?? load
        power = powerReader.read()
        // The process list (a scan of every process) every other refresh: still current, half the cost.
        if force || refreshes <= 2 || refreshes % 2 == 0 { processes = processReader.top(8) }
        temperatures = temperatureReader.read(cpuOnly: true)   // the 18 CPU sensors, ~1.7 ms
        if let measured = thermal.read().frequencies { speeds = measured }   // keep the last while a new baseline is taken
    }

    /// The speed one core ran at while working (MHz), 0 if it rested, nil if unknown.
    func speed(ofCore index: Int) -> Double? {
        let kinds = CPUReader.coreKinds
        guard let speeds, index < kinds.count else { return nil }
        let position = kinds[..<index].filter { $0 == kinds[index] }.count   // its place within its group
        let isP = kinds[index] == .performance
        guard position < Int(isP ? speeds.pCount : speeds.eCount) else { return nil }
        return withUnsafeBytes(of: isP ? speeds.pCoreMHz : speeds.eCoreMHz) { $0.bindMemory(to: Double.self)[position] }
    }

    func topSpeed(_ kind: CoreKind) -> Double? {
        guard let speeds else { return nil }
        return kind == .performance ? speeds.pMaxMHz : speeds.eMaxMHz
    }

    /// The hottest sensor of one group of cores.
    func temperature(_ kind: CoreKind) -> Double? {
        (kind == .performance ? temperatures?.pCores : temperatures?.eCores)?.max()
    }

    /// Asks the app to quit, like ⌘Q: it may still ask to save your work.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh(force: true) }
    }

    /// Average load of one kind of core, nil if the Mac doesn't say which core is which.
    func average(_ kind: CoreKind) -> Double? {
        guard let load, CPUReader.coreKinds.count == load.cores.count else { return nil }
        let values = zip(load.cores, CPUReader.coreKinds).filter { $0.1 == kind }.map(\.0)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

struct CPUView: View {
    @ObservedObject var model: CPUModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section { summary }

            HistoryPanel(tr("История", "History"), metric: .cpu,
                         format: { String(format: "%.0f%%", $0) }, hoverIndex: $model.hoverIndex)

            Section(tr("По ядра", "Per core")) {
                CoreColumns(model: model)
                    .padding(.vertical, 4)
            }

            Section {
                if model.processes.isEmpty {
                    Text(tr("Измерване…", "Measuring…")).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {   // one Form cell for the whole list: far cheaper to refresh than a cell per row
                    ForEach(Array(model.processes.enumerated()), id: \.element.id) { index, process in
                        if index > 0 { Divider().padding(.vertical, 6) }
                        HStack(spacing: 10) {
                            icon(process)
                            Text(process.name)
                            Spacer()
                            Text(String(format: "%.1f%%", process.percent))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            QuitSlot(app: process.app, canQuit: process.canQuit, quit: model.quit)
                        }
                    }
                }
            } header: {
                Text(tr("Кой натоварва най-много", "Using the most CPU"))
            } footer: {
                Text(tr("100% = едно ядро, заето изцяло. Помощните процеси се броят към приложението си. Системните (WindowServer, kernel_task) не се виждат без администраторски права.",
                        "100% = one core fully busy. Helper processes count toward their app. System ones (WindowServer, kernel_task) need admin rights to be seen."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }


    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.load.map { String(format: "%.0f%%", $0.total) } ?? "–")
                    .font(.system(size: 34, weight: .semibold))   // proportional digits for the big number
                Text(tr("Натоварване", "Load")).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = model.average(.performance) {
                tile(tr("P-ядра", "P-cores"), String(format: "%.0f%%", p))
            }
            if let e = model.average(.efficiency) {
                tile(tr("E-ядра", "E-cores"), String(format: "%.0f%%", e))
            }
            if let hottest = model.temperatures?.cpu {
                tile(tr("Температура", "Temperature"), degrees(hottest))
            }
            if let power = model.power {
                tile(tr("Мощност", "Power"), watts(power.cpu))
                    .help(tr("P-ядра ", "P-cores ") + watts(power.pCores) + " · " + tr("E-ядра ", "E-cores ") + watts(power.eCores))
            }
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func icon(_ process: ProcessCPU) -> some View {
        AppIconView(image: AppIcons.small(app: process.app))
    }
}

// MARK: - Per-core columns

/// One thin meter per core, grouped into P and E, with a panel on the right that explains
/// the core under the mouse. The track behind each column is a lighter step of the same blue,
/// so the share reads against the full 100%.
private struct CoreColumns: View {
    @ObservedObject var model: CPUModel

    var body: some View {
        let cores = model.load?.cores ?? []
        let kinds = CPUReader.coreKinds
        HStack(alignment: .top, spacing: 28) {
            if kinds.count == cores.count, !cores.isEmpty {
                group(.performance, cores.indices.filter { kinds[$0] == .performance }, cores)
                group(.efficiency, cores.indices.filter { kinds[$0] == .efficiency }, cores)
            } else {
                group(nil, Array(cores.indices), cores)
            }
            Spacer(minLength: 0)
            inspector(cores, kinds)
                .frame(width: 190, alignment: .leading)
        }
    }

    private func group(_ kind: CoreKind?, _ indices: [Int], _ cores: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.map(title) ?? tr("Ядра", "Cores")).font(.callout).foregroundStyle(.secondary)
                if let kind {   // the group's hottest spot and speed while working
                    Text([model.temperature(kind).map(degrees), groupSpeed(kind)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(indices.enumerated()), id: \.element) { position, core in
                    VStack(spacing: 4) {
                        column(cores[core], highlighted: model.coreHover == core)
                        Text("\(position + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { model.coreHover = core } else if model.coreHover == core { model.coreHover = nil }
                    }
                }
            }
        }
    }

    private func title(_ kind: CoreKind) -> String {
        kind == .performance ? tr("Мощни (P)", "Performance (P)") : tr("Пестеливи (E)", "Efficiency (E)")
    }

    private func groupSpeed(_ kind: CoreKind) -> String? {
        guard let speeds = model.speeds else { return nil }
        let mhz = kind == .performance ? speeds.pMHz : speeds.eMHz
        return mhz > 0 ? String(format: "%.2f GHz", mhz / 1000) : nil
    }

    /// Details of the core under the mouse, or a hint when there is none.
    @ViewBuilder
    private func inspector(_ cores: [Double], _ kinds: [CoreKind]) -> some View {
        if let core = model.coreHover, cores.indices.contains(core) {
            let kind = kinds.indices.contains(core) ? kinds[core] : nil
            let position = kind.map { k in kinds[..<core].filter { $0 == k }.count + 1 } ?? core + 1
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .performance ? tr("Мощно ядро \(position)", "Performance core \(position)")
                     : kind == .efficiency ? tr("Пестеливо ядро \(position)", "Efficiency core \(position)")
                     : tr("Ядро \(position)", "Core \(position)"))
                    .font(.headline)
                detail(tr("Натоварване", "Load"), String(format: "%.0f%%", cores[core]))
                if let mhz = model.speed(ofCore: core) {
                    detail(tr("Честота", "Speed"), mhz > 0
                           ? String(format: tr("%.2f от %.2f GHz", "%.2f of %.2f GHz"), mhz / 1000, (kind.flatMap { model.topSpeed($0) } ?? mhz) / 1000)
                           : tr("почива", "resting"))
                }
                if let kind, let temperature = model.temperature(kind) {
                    detail(tr("Температура", "Temperature"), degrees(temperature) + tr(" (групата)", " (group)"))
                }
                Text(kind == .performance
                     ? tr("За тежки задачи: игри, компилиране, експорт на видео. Харчат повече.",
                          "For heavy work: games, compiling, video export. They use more power.")
                     : tr("За леки и фонови задачи: поща, музика, синхронизиране. Пестят батерия.",
                          "For light and background work: mail, music, syncing. They save battery."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        } else {
            Text(tr("Посочи ядро с мишката за подробности.", "Point at a core for details."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func column(_ load: Double, highlighted: Bool) -> some View {
        let height: CGFloat = 64
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)   // square at the baseline
        return ZStack(alignment: .bottom) {
            shape.fill(.blue.opacity(highlighted ? 0.3 : 0.15)).frame(height: height)
            shape.fill(.blue).frame(height: max(2, height * CGFloat(min(load, 100) / 100)))
        }
        .frame(width: 14)
    }
}
