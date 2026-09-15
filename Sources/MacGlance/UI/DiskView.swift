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
            ssd = ssdReader.read()
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
