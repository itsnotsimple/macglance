import AppKit
import SwiftUI

/// Live data for the CPU page. Refreshes only while the page is on screen.
final class CPUModel: ObservableObject {
    @Published private(set) var load: CPULoad?
    @Published private(set) var power: PowerUsage?
    @Published private(set) var processes: [ProcessCPU] = []
    @Published var hoverIndex: Int?   // history sample under the mouse
    private let cpu = CPUReader()
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

    func refresh() {
        load = cpu.read() ?? load
        power = powerReader.read()
        processes = processReader.top(8)
    }

    /// Asks the app to quit, like ⌘Q: it may still ask to save your work.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
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
                ForEach(model.processes) { process in
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
        HStack(alignment: .firstTextBaseline, spacing: 28) {
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

    @ViewBuilder
    private func icon(_ process: ProcessCPU) -> some View {
        if let icon = process.app?.icon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "gearshape.2")   // background process, no app icon
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}

// MARK: - Per-core columns

/// One thin meter per core, grouped into P and E. The track behind each column is a lighter
/// step of the same blue, so the share reads against the full 100%.
private struct CoreColumns: View {
    @ObservedObject var model: CPUModel

    var body: some View {
        let cores = model.load?.cores ?? []
        let kinds = CPUReader.coreKinds
        HStack(alignment: .bottom, spacing: 32) {
            if kinds.count == cores.count, !cores.isEmpty {
                group(tr("Мощни (P)", "Performance (P)"), "P", cores.indices.filter { kinds[$0] == .performance }, cores)
                group(tr("Пестеливи (E)", "Efficiency (E)"), "E", cores.indices.filter { kinds[$0] == .efficiency }, cores)
            } else {
                group(tr("Ядра", "Cores"), "", Array(cores.indices), cores)
            }
            Spacer()
        }
    }

    private func group(_ title: String, _ prefix: String, _ indices: [Int], _ cores: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(indices.enumerated()), id: \.element) { position, core in
                    VStack(spacing: 4) {
                        column(cores[core])
                        Text("\(position + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .help("\(prefix)\(position + 1): " + String(format: "%.0f%%", cores[core]))
                }
            }
        }
    }

    private func column(_ load: Double) -> some View {
        let height: CGFloat = 64
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)   // square at the baseline
        return ZStack(alignment: .bottom) {
            shape.fill(.blue.opacity(0.15)).frame(height: height)
            shape.fill(.blue).frame(height: max(2, height * CGFloat(min(load, 100) / 100)))
        }
        .frame(width: 14)
    }
}
