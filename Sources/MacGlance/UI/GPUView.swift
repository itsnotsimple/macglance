import AppKit
import SwiftUI

/// Live data for the GPU page. Refreshes only while the page is on screen.
final class GPUModel: ObservableObject {
    @Published private(set) var stats: GPUStats?
    @Published private(set) var watts: Double?
    @Published private(set) var temperature: Double?
    @Published private(set) var processes: [ProcessGPU] = []
    @Published var hoverIndex: Int?   // history sample under the mouse
    private let gpu = GPUReader()
    private let power = PowerReader()
    private let temperatures = TemperatureReader()
    private let processReader = ProcessGPUReader()
    private var timer: Timer?

    func start() {
        refresh()   // baseline for the per-app numbers
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
        stats = gpu.read()
        watts = power.read()?.gpu
        temperature = temperatures.gpuTemperature()
        processes = processReader.top(8)
    }

    /// Asks the app to quit, like ⌘Q: it may still ask to save your work.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }
}

struct GPUView: View {
    @ObservedObject var model: GPUModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section { summary }

            HistoryPanel(tr("История", "History"), metric: .gpu,
                         format: { String(format: "%.0f%%", $0) }, hoverIndex: $model.hoverIndex)

            Section(tr("Детайли", "Details")) {
                if let info = GPUReader.info {
                    row(tr("Чип", "Chip"), tr("\(info.model) · \(info.cores) GPU ядра", "\(info.model) · \(info.cores) GPU cores"))
                }
                if let stats = model.stats {
                    row(tr("Рендериране", "Rendering"), "\(stats.renderer)%")
                        .help(tr("Етапът, който оцветява пикселите", "The stage that colors the pixels"))
                    row(tr("Геометрия (tiler)", "Geometry (tiler)"), "\(stats.tiler)%")
                        .help(tr("Етапът, който разпределя триъгълниците по части от екрана",
                                 "The stage that sorts triangles into parts of the screen"))
                }
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
                Text(tr("Кой ползва видеокартата", "Using the GPU"))
            } footer: {
                Text(tr("Процент от времето на видеокартата. Тук се виждат и системните процеси: WindowServer рисува целия екран.",
                        "Share of the GPU's time. System processes show up here too: WindowServer draws the whole screen."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }


    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.stats.map { "\($0.load)%" } ?? "–")
                    .font(.system(size: 34, weight: .semibold))
                Text(tr("Натоварване", "Load")).foregroundStyle(.secondary)
            }
            Spacer()
            tile(tr("Мощност", "Power"), model.watts.map(watts) ?? "–")
            tile(tr("Температура", "Temperature"), model.temperature.map(degrees) ?? "–")
            tile(tr("Памет", "Memory"), model.stats?.memoryInUse.map(memoryText) ?? "–")
                .help(tr("RAM, която видеокартата ползва в момента (паметта е обща с процесора)",
                         "RAM the GPU is using right now (memory is shared with the CPU)"))
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

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func icon(_ process: ProcessGPU) -> some View {
        if let icon = process.app?.icon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "gearshape.2")   // background process, no app icon
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}
