import AppKit
import SwiftUI

/// Live data for the Disk page. Refreshes only while the page is on screen;
/// the SSD's health log once a minute (it changes slowly).
final class DiskModel: ObservableObject {
    @Published private(set) var disk: DiskUsage?
    @Published private(set) var ssd: SSDHealth?
    @Published private(set) var swap: UInt64?
    private let diskReader = DiskReader()
    private let ssdReader = SSDReader()
    private let memory = MemoryReader()
    private var timer: Timer?
    private var lastSMART = Date.distantPast

    func start() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }   // speeds need two samples
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
        disk = diskReader.read()
        swap = memory.read()?.swap
        if Date().timeIntervalSince(lastSMART) >= 60 {
            lastSMART = Date()
            ssd = ssdReader.read() ?? ssd   // a reading can fail if another app reads it that very moment
        }
    }
}

struct DiskView: View {
    @ObservedObject var model: DiskModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            if let disk = model.disk {
                Section { summary(disk) }
            }

            CacheSection()

            if let ssd = model.ssd {
                Section {
                    Label {
                        Text(ssd.isHealthy ? tr("SSD-то е в добро състояние", "The SSD is in good shape")
                                           : tr("SSD-то съобщава за проблем: направи си резервно копие", "The SSD reports a problem: back up your data"))
                    } icon: {
                        Image(systemName: ssd.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ssd.isHealthy ? .green : .orange)
                    }
                    HStack {
                        Text(tr("Износване", "Wear"))
                        Spacer()
                        Meter(fraction: Double(ssd.wearPercent) / 100)
                            .frame(width: 120)
                        value("\(ssd.wearPercent)%")
                    }
                    .help(tr("0% = нов. 100% = изразходван предвиденият живот (дискът може да работи и след това).",
                             "0% = new. 100% = rated life used up (the drive can keep working past it)."))
                    row(tr("Записани днес", "Written today"), bytesText(ssd.writtenToday))
                    row(tr("Записани общо", "Written in total"), bytesText(ssd.written))
                    row(tr("Прочетени общо", "Read in total"), bytesText(ssd.read))
                    row(tr("Резервни блокове", "Spare blocks"), "\(ssd.spare)%")
                    row(tr("Часове работа", "Power-on hours"), "\(ssd.powerOnHours)")
                    row(tr("Включвания", "Power cycles"), "\(ssd.powerCycles)")
                    row(tr("Неправилни изключвания", "Unsafe shutdowns"), "\(ssd.unsafeShutdowns)")
                        .help(tr("Изключване без нормално спиране: изтощена батерия, задържан бутон за захранване",
                                 "Power lost without a clean shutdown: a dead battery, holding the power button"))
                    row(tr("Грешки", "Media errors"), "\(ssd.mediaErrors)")
                } header: {
                    Text(tr("Здраве на SSD-то", "SSD health"))
                } footer: {
                    Text(swapNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(tr("Здраве на SSD-то", "SSD health")) {
                    Text(tr("Този диск не дава данни за здравето си.", "This drive doesn't report its health."))
                        .foregroundStyle(.secondary)
                }
            }

            WritersSection(liveTotal: model.disk?.writePerSecond)
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var swapNote: String {
        let swap = model.swap.map { bytesText(Double($0)) } ?? "–"
        return tr("Данните идват от самия диск (NVMe SMART). Клетките на SSD-то се износват при запис. Честа причина за много записи е swap: когато RAM не стига, macOS пише паметта на диска. Swap сега: \(swap).",
                  "The numbers come from the drive itself (NVMe SMART). SSD cells wear with writes. A common cause of heavy writing is swap: when RAM runs short, macOS writes memory to disk. Swap right now: \(swap).")
    }

    private func summary(_ disk: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(diskText(disk.free)).font(.system(size: 34, weight: .semibold))
                    Text(tr("свободни от ", "free of ") + diskText(disk.total)).foregroundStyle(.secondary)
                }
                Spacer()
                tile(tr("Четене", "Read"), disk.readPerSecond.map(speedText) ?? "…")
                tile(tr("Запис", "Write"), disk.writePerSecond.map(speedText) ?? "…")
                if let temperature = model.ssd?.temperature {
                    tile(tr("Температура", "Temperature"), degrees(Double(temperature)))
                }
            }
            Meter(fraction: 1 - Double(disk.free) / Double(max(disk.total, 1)))
                .help(tr("Заето място", "Space used"))
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            value(text)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).monospacedDigit().foregroundStyle(.secondary)
    }
}

/// A share of a whole: the fill on a lighter track of the same blue.
private struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.blue.opacity(0.15))
                Capsule().fill(.blue).frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Who writes

/// The apps that write the most to the SSD: right now, today, or over the last 7 or 30 days.
/// Each row says what it is; an app can be quit, shown in Finder or moved to the Trash.
private struct WritersSection: View {
    let liveTotal: Double?   // the whole disk's write speed, for "The rest" under "Now"
    @ObservedObject private var writers = DiskWriters.shared
    @ObservedObject private var live = LiveWriters.shared
    @ObservedObject private var settings = Settings.shared
    @State private var period = 1   // 0 = now, otherwise days
    @State private var trashing: Item?
    @State private var result: String?

    /// One row, whichever period it comes from.
    struct Item: Identifiable {
        let id: String      // the name shown
        let key: String
        let icon: String?
        let value: String
    }

    var body: some View {
        Section {
            Picker("", selection: $period) {
                Text(tr("Сега", "Now")).tag(0)
                Text(tr("Днес", "Today")).tag(1)
                Text(tr("7 дни", "7 days")).tag(7)
                Text(tr("30 дни", "30 days")).tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let (items, rest) = content
            if items.isEmpty {
                Text(period == 0
                     ? (live.ready ? tr("В момента никое приложение не пише осезаемо.", "No app is writing much right now.")
                                   : tr("Измерване…", "Measuring…"))
                     : tr("Събира се… (обновява се веднъж на минута)", "Collecting… (updates once a minute)"))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {   // one cell for the whole list: much lighter to draw than a cell per row
                    ForEach(items) { item in
                        if item.id != items.first?.id { Divider() }
                        row(item)
                    }
                    if let rest {
                        Divider()
                        restRow(rest)
                    }
                }
            }
            if let result {
                Text(result).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text(tr("Кой пише най-много по SSD-то", "Who writes the most to the SSD"))
        } footer: {
            Text(footer)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { if period == 0 { live.start() } }
        .onDisappear { live.stop() }
        .onChange(of: period) { _, now in
            result = nil
            if now == 0 { live.start() } else { live.stop() }
        }
        .confirmationDialog(trashing.map { tr("Да преместя \($0.id) в кошчето?", "Move \($0.id) to the Trash?") } ?? "",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            presenting: trashing) { item in
            Button(tr("Затвори и премести в кошчето", "Quit and move to Trash"), role: .destructive) { trash(item) }
            Button(tr("Отказ", "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(tr("Приложението ще се затвори и ще отиде в кошчето: можеш да го върнеш оттам, докато не го изпразниш. Настройките и данните му остават.",
                    "The app quits and goes to the Trash: you can put it back from there until you empty it. Its settings and data stay."))
        }
    }

    /// The rows for the chosen period, and what the SSD wrote beyond them ("The rest"), if it's worth a row.
    private var content: ([Item], Double?) {
        if period == 0 {
            let items = live.rows.map { Item(id: $0.id, key: $0.key, icon: $0.icon, value: speedText($0.perSecond)) }
            let rest = liveTotal.map { $0 - live.rows.map(\.perSecond).reduce(0, +) }
            return (items, live.ready && (rest ?? 0) >= 100_000 ? rest : nil)
        }
        let items = writers.top(days: period).map { Item(id: $0.id, key: $0.key, icon: $0.icon, value: bytesText($0.bytes)) }
        let rest = writers.ssdWritten(days: period).map { $0 - writers.total(days: period) }
        return (items, (rest ?? 0) >= 1e6 ? rest : nil)
    }

    private func row(_ item: Item) -> some View {
        let app = WriterTips.running(item.key)
        let installed = WriterTips.installed(item.key)
        return HStack(spacing: 10) {
            AppIconView(image: item.icon.flatMap { AppIcons.small(bundleID: $0) })
            VStack(alignment: .leading, spacing: 1) {
                Text(item.id).lineLimit(1)
                if let note = WriterTips.note(key: item.key) {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(item.value).monospacedDigit().foregroundStyle(.secondary)
            QuitSlot(app: app, canQuit: app != nil) { $0.terminate() }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let app {
                Button(tr("Затвори", "Quit")) { app.terminate() }
            }
            if let installed {
                Button(tr("Покажи във Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([installed]) }
                Divider()
                Button(tr("Премести в кошчето…", "Move to Trash…")) { trashing = item }
            }
            if app == nil && installed == nil {
                Text(tr("Част от macOS: не може да се затвори или изтрие", "Part of macOS: can't be quit or removed"))
            }
        }
        .help(installed != nil ? tr("Десен бутон: покажи във Finder или премести в кошчето",
                                    "Right-click: show in Finder or move to the Trash") : "")
    }

    private func restRow(_ value: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "applelogo").foregroundStyle(.secondary).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Останалото: macOS и кратки програми", "The rest: macOS and short-lived programs")).lineLimit(1)
                Text(tr("Swap, Spotlight, системни дневници. Нормално.", "Swap, Spotlight, system logs. Normal."))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            Spacer()
            Text(period == 0 ? speedText(value) : bytesText(value)).monospacedDigit().foregroundStyle(.secondary)
            QuitSlot(app: nil, canQuit: false) { _ in }
        }
        .help(tr("Колкото е отчело самото SSD, минус приложенията отгоре: swap, индексът на Spotlight, системните дневници, Time Machine и програми, приключили за по-малко от минута.",
                 "What the SSD itself counted, minus the apps above: swap, the Spotlight index, system logs, Time Machine and programs that ended within a minute."))
    }

    private func trash(_ item: Item) {
        guard let url = WriterTips.installed(item.key) else { return }
        result = tr("Затварям \(item.id)…", "Quitting \(item.id)…")
        WriterTips.quitAndTrash(key: item.key, url: url) { done in
            result = done
                ? tr("\(item.id) е в кошчето. Можеш да го върнеш оттам.", "\(item.id) is in the Trash. You can put it back from there.")
                : tr("\(item.id) не се затвори (може би пита да запазиш нещо). Затвори го и опитай пак.",
                     "\(item.id) didn't quit (it may be asking to save something). Quit it and try again.")
        }
    }

    private var footer: String {
        if period == 0 {
            return tr("Колко пише всяко приложение в момента; обновява се на 2 секунди, само докато гледаш. Десен бутон върху приложение: Finder или кошчето.",
                      "How fast each app is writing right now, updated every 2 seconds while you look. Right-click an app: Finder or the Trash.")
        }
        var text = tr("Колко е записало всяко приложение на диска; проверява се веднъж на минута. Части от macOS, които искат админ права (swap, част от Spotlight, Time Machine), и програми, приключили за секунди, не се виждат поотделно: те са в „Останалото“.",
                      "How much each app wrote to the disk, checked once a minute. Parts of macOS that need admin rights (swap, part of Spotlight, Time Machine) and programs that ended within seconds can't be seen one by one: they're in “The rest”.")
        let start = writers.countingSince
        let periodStart = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -(period - 1), to: Date()) ?? Date())
        if start > periodStart {   // the list doesn't cover the whole period yet
            let format = DateFormatter()
            format.dateFormat = "d.MM HH:mm"
            text += tr(" Броенето започна на \(format.string(from: start)).", " Counting started on \(format.string(from: start)).")
        }
        return text
    }
}

// MARK: - App caches

/// Scan → a list of apps' caches with sizes and ticks → clear the ticked ones (after a confirmation).
private struct CacheSection: View {
    @ObservedObject private var cleaner = CacheCleaner.shared
    @ObservedObject private var settings = Settings.shared
    @State private var confirming = false   // (@State compiles fine since Xcode is installed)

    var body: some View {
        Section {
            HStack {
                Button(cleaner.scanned ? tr("Сканирай пак", "Scan again") : tr("Сканирай", "Scan")) { cleaner.scan() }
                    .disabled(cleaner.state != .idle)
                if cleaner.state == .scanning {
                    ProgressView().controlSize(.small)
                    Text(tr("Сканиране…", "Scanning…")).foregroundStyle(.secondary)
                } else if cleaner.state == .cleaning {
                    ProgressView().controlSize(.small)
                    Text(tr("Изчистване…", "Clearing…")).foregroundStyle(.secondary)
                } else if let freed = cleaner.lastFreed {
                    Text(tr("Освободени ", "Freed ") + bytesText(Double(freed))).foregroundStyle(.secondary)
                }
                Spacer()
                if cleaner.scanned, !cleaner.entries.isEmpty {
                    Button(tr("Изчисти избраното", "Clear selected") + " (" + bytesText(Double(cleaner.selectedBytes)) + ")") {
                        confirming = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleaner.selectedBytes == 0 || cleaner.state != .idle)
                }
            }
            if cleaner.scanned && cleaner.entries.isEmpty && cleaner.state == .idle {
                Text(tr("Няма кеш на приложения за изчистване.", "No app caches to clear.")).foregroundStyle(.secondary)
            }
            ForEach(cleaner.entries) { entry in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { cleaner.selected.contains(entry.id) && !entry.isRunning },
                        set: { on in if on { cleaner.selected.insert(entry.id) } else { cleaner.selected.remove(entry.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(entry.isRunning)
                    AppIconView(image: AppIcons.small(bundleID: entry.bundleID))
                    Text(entry.name).lineLimit(1)
                    if entry.isRunning {
                        Text(tr("отворено: затвори го, за да изчистиш", "open: quit it to clear"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(bytesText(Double(entry.bytes))).monospacedDigit().foregroundStyle(.secondary)
                }
                .opacity(entry.isRunning ? 0.55 : 1)
            }
        } header: {
            Text(tr("Кеш на приложенията", "App caches"))
        } footer: {
            Text(tr("Само кеш на инсталирани приложения: те си го създават наново сами, така че нищо лично не се губи. Кешът на macOS, на програмистки инструменти и на отворени приложения не се пипа. Първото отваряне след това може да е малко по-бавно.",
                    "Only caches of installed apps: they rebuild them by themselves, so nothing personal is lost. macOS's own caches, developer tools and open apps are left alone. The first launch afterwards can be a little slower."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(tr("Да изчистя кеша на избраните приложения?", "Clear the cache of the selected apps?"),
                            isPresented: $confirming) {
            Button(tr("Изчисти ", "Clear ") + bytesText(Double(cleaner.selectedBytes)), role: .destructive) { cleaner.clean() }
            Button(tr("Отказ", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Приложенията ще си го създадат наново, когато ги отвориш.", "The apps will rebuild it the next time you open them."))
        }
    }
}
