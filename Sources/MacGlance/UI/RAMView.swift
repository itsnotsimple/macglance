import AppKit
import SwiftUI

/// Live data for the RAM page. Refreshes only while the page is on screen.
final class RAMModel: ObservableObject {
    @Published private(set) var usage: MemoryUsage?
    @Published private(set) var apps: [AppMemory] = []
    private let memory = MemoryReader()
    private let appMemory = AppMemoryReader()
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
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
        usage = memory.read()
        // Memory per app changes slowly and the scan costs ~7 ms: every third refresh is enough.
        if force || refreshes == 1 || refreshes % 3 == 0 { apps = appMemory.top(8) }
    }

    /// Asks the app to quit, like ⌘Q: it may still ask to save your work.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh(force: true) }
    }
}

struct RAMView: View {
    @ObservedObject var model: RAMModel
    @ObservedObject private var cleaner = RAMCleaner.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            if let usage = model.usage {
                Section { summary(usage) }
            }

            Section {
                HStack {
                    Button(tr("Освободи RAM", "Free up RAM")) { cleaner.run() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(cleaner.isRunning)
                    if cleaner.isRunning {
                        ProgressView().controlSize(.small)
                        Text(tr("Освобождаване…", "Freeing…")).foregroundStyle(.secondary)
                    } else if let freed = cleaner.lastFreed {
                        Text(freed > 0
                             ? tr("Освободени ", "Freed ") + memoryText(UInt64(freed))
                             : tr("Нямаше какво да се освободи", "Nothing to free"))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(tr("macOS компресира паметта на приложенията, които не ползваш. Числото пада, но те се връщат малко по-бавно, когато ги отвориш. Реално RAM се освобождава само като затвориш приложение.",
                        "macOS compresses the memory of apps you are not using. The number drops, but those apps take a moment longer to come back. RAM only really frees up when you quit an app."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(tr("Автоматично", "Automatic")) {
                Picker(tr("Освобождавай RAM", "Free up RAM"), selection: $settings.autoCleanMinutes) {
                    Text(tr("никога", "never")).tag(0)
                    Text(tr("на 15 минути", "every 15 minutes")).tag(15)
                    Text(tr("на 30 минути", "every 30 minutes")).tag(30)
                    Text(tr("на всеки час", "every hour")).tag(60)
                }
                Picker(tr("Само ако RAM е над", "Only if RAM is above"), selection: $settings.autoCleanAbove) {
                    Text(tr("без значение", "any level")).tag(0)
                    Text("60%").tag(60)
                    Text("70%").tag(70)
                    Text("80%").tag(80)
                }
                .disabled(settings.autoCleanMinutes == 0)
                Toggle(tr("Известие след всяко освобождаване", "Notify after each clean-up"), isOn: $settings.notifyOnClean)
            }

            Section(tr("Кой държи най-много", "Using the most")) {
                ForEach(model.apps) { item in
                    HStack(spacing: 10) {
                        AppIconView(image: AppIcons.small(app: item.app))
                        Text(item.app.localizedName ?? "?")
                        Spacer()
                        Text(memoryText(item.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button(tr("Затвори", "Quit")) { model.quit(item.app) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: cleaner.isRunning) { _, running in
            if !running { model.refresh(force: true) }   // show the result right away
        }
    }

    private func summary(_ usage: MemoryUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(memoryText(usage.used))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text(tr("от ", "of ") + memoryText(usage.total)).foregroundStyle(.secondary)
                Spacer()
                pressureBadge(usage.pressure)
            }
            UsageBar(usage: usage)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow {
                    legend(.blue, tr("Приложения", "Apps"), usage.app)
                    legend(.purple, tr("Компресирана", "Compressed"), usage.compressed)
                }
                GridRow {
                    legend(.orange, tr("Система", "System"), usage.wired)
                    legend(.gray, "Swap", usage.swap)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func pressureBadge(_ pressure: MemoryPressure) -> some View {
        let (color, text): (Color, String) = switch pressure {
        case .normal: (.green, tr("Натиск: нормален", "Pressure: normal"))
        case .warning: (.yellow, tr("Натиск: повишен", "Pressure: elevated"))
        case .critical: (.red, tr("Натиск: критичен", "Pressure: critical"))
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    private func legend(_ color: Color, _ label: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary)
            Text(memoryText(bytes)).monospacedDigit()
        }
    }
}

/// One bar for all of RAM: apps, system, compressed, and the rest (free + file cache).
private struct UsageBar: View {
    let usage: MemoryUsage

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let part = { (bytes: UInt64) in width * CGFloat(Double(bytes) / Double(usage.total)) }
            HStack(spacing: 1) {
                Rectangle().fill(.blue).frame(width: part(usage.app))
                Rectangle().fill(.orange).frame(width: part(usage.wired))
                Rectangle().fill(.purple).frame(width: part(usage.compressed))
                Rectangle().fill(.quaternary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 14)
    }
}
