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

            WritersSection()
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

/// The apps that wrote the most to the SSD, today or over the last 7 days.
private struct WritersSection: View {
    @ObservedObject private var writers = DiskWriters.shared
    @ObservedObject private var settings = Settings.shared
    @State private var week = false

    var body: some View {
        Section {
            Picker("", selection: $week) {
                Text(tr("Днес", "Today")).tag(false)
                Text(tr("Последните 7 дни", "Last 7 days")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let period = week ? 7 : 1
            let rows = writers.top(days: period)
            let rest = writers.ssdWritten(days: period).map { $0 - writers.total(days: period) }
            if rows.isEmpty {
                Text(tr("Събира се… (обновява се веднъж на минута)", "Collecting… (updates once a minute)"))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {   // one cell for the whole list: much lighter to draw than a cell per row
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider() }
                        HStack(spacing: 10) {
                            AppIconView(image: row.icon.flatMap { AppIcons.small(bundleID: $0) })
                            Text(row.id).lineLimit(1)
                            Spacer()
                            Text(bytesText(row.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if let rest, rest >= 1e6 {
                        Divider()
                        HStack(spacing: 10) {
                            Image(systemName: "applelogo").foregroundStyle(.secondary).frame(width: 22, height: 22)
                            Text(tr("Останалото: macOS и кратки програми", "The rest: macOS and short-lived programs")).lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(bytesText(rest)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .help(tr("Колкото е отчело самото SSD, минус приложенията отгоре: swap, индексът на Spotlight, системните дневници, Time Machine и програми, приключили за по-малко от минута.",
                                 "What the SSD itself counted, minus the apps above: swap, the Spotlight index, system logs, Time Machine and programs that ended within a minute."))
                    }
                }
            }
        } header: {
            Text(tr("Кой пише най-много по SSD-то", "Who writes the most to the SSD"))
        } footer: {
            Text(footer)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var text = tr("Колко е записало всяко приложение на диска; проверява се веднъж на минута. Части от macOS, които искат админ права (swap, част от Spotlight, Time Machine), и програми, приключили за секунди, не се виждат поотделно: те са в „Останалото“.",
                      "How much each app wrote to the disk, checked once a minute. Parts of macOS that need admin rights (swap, part of Spotlight, Time Machine) and programs that ended within seconds can't be seen one by one: they're in “The rest”.")
        let start = writers.countingSince
        let periodStart = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: week ? -6 : 0, to: Date()) ?? Date())
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
