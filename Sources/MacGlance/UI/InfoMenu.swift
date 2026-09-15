import AppKit

/// The menu under the menu bar text: live numbers, Free up RAM, Settings…, Quit.
/// The number rows are only rewritten while the menu is open.
final class InfoMenu: NSObject, NSMenuDelegate {
    enum Row { case ram, swap, pressure, system, cpu, gpu, other, topApps, app1, app2, app3, adapter, battery, temperature, disk, diskRead, diskWrite, network }

    let menu = NSMenu()
    private(set) var isOpen = false
    private var rows: [Row: NSMenuItem] = [:]
    private var freeRAMItem = NSMenuItem()
    private var memory: MemoryUsage?
    private var power: PowerUsage?
    private var disk: DiskUsage?
    private var network: NetworkUsage?
    private var temperature: Temperatures?
    private var topApps: [AppEnergy] = []
    private let onOpen: () -> Void
    private let openSettings: () -> Void

    init(onOpen: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.onOpen = onOpen
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        rebuild()
    }

    /// Builds all items again, e.g. after the language changed.
    func rebuild() {
        menu.removeAllItems()
        if let release = Updater.shared.available {   // the update offer goes on top, so it's seen
            let update = NSMenuItem(title: tr("Обнови до версия \(release.version)…", "Update to version \(release.version)…"),
                                    action: #selector(settingsClicked), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
        }
        add(.ram)
        add(.swap)
        add(.pressure)
        freeRAMItem = NSMenuItem(title: "", action: #selector(freeRAMClicked), keyEquivalent: "")
        freeRAMItem.target = self
        menu.addItem(freeRAMItem)
        menu.addItem(.separator())
        add(.system)
        add(.cpu, indent: 1)
        add(.gpu, indent: 1)
        add(.other, indent: 1)
        add(.topApps)
        add(.app1, indent: 1)
        add(.app2, indent: 1)
        add(.app3, indent: 1)
        add(.adapter)
        add(.battery)
        add(.temperature)
        menu.addItem(.separator())
        add(.disk)
        add(.diskRead, indent: 1)
        add(.diskWrite, indent: 1)
        add(.network)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: tr("Настройки…", "Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: tr("Изход", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        refresh()
    }

    func update(memory: MemoryUsage?, power: PowerUsage?, disk: DiskUsage?, network: NetworkUsage?, temperature: Temperatures?,
                topApps: [AppEnergy]) {
        self.memory = memory
        self.power = power
        self.disk = disk
        self.network = network
        self.temperature = temperature
        if !topApps.isEmpty { self.topApps = topApps }   // keep the last list while a new baseline is taken
        if isOpen { refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        onOpen()   // fresh numbers right away instead of up to one tick later
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    @objc private func freeRAMClicked() {
        RAMCleaner.shared.run()
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    // MARK: - Rows

    private func label(_ row: Row) -> String {
        switch row {
        case .ram: "RAM"
        case .swap: "Swap"
        case .pressure: tr("Натиск", "Pressure")
        case .system: tr("Цялата система", "Whole system")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .other: tr("Останалото", "Everything else")   // screen, RAM, SSD, power conversion
        case .adapter: tr("Зарядно", "Charger")
        case .battery: tr("Батерия", "Battery")
        case .topApps: tr("Най-много харчат", "Using the most")
        case .app1, .app2, .app3: ""
        case .temperature: tr("Температура", "Temperature")
        case .disk: tr("Диск", "Disk")
        case .diskRead: tr("Четене", "Read")
        case .diskWrite: tr("Запис", "Write")
        case .network: tr("Мрежа", "Network")
        }
    }

    private func refresh() {
        if let m = memory {
            set(.ram, String(format: tr("%.1f от %.0f GB", "%.1f of %.0f GB"), gb(m.used), gb(m.total)))
            set(.swap, String(format: "%.1f GB", gb(m.swap)))
            let pressure = switch m.pressure {
            case .normal: tr("🟢 нормален", "🟢 normal")
            case .warning: tr("🟡 повишен", "🟡 elevated")
            case .critical: tr("🔴 критичен", "🔴 critical")
            }
            set(.pressure, pressure)
        }
        set(.topApps, "")
        for (index, row) in [Row.app1, .app2, .app3].enumerated() {
            if topApps.indices.contains(index) {
                let app = topApps[index]
                set(row, watts(app.watts), label: app.name)
            } else {
                set(row, index == 0 ? "…" : "", label: "")   // "…" until the first measurement
            }
        }
        if let t = temperature {
            let gpu = t.gpuMax.map { "   GPU " + degrees($0) } ?? ""
            set(.temperature, "CPU " + (t.cpu.map(degrees) ?? "–") + gpu)
        }
        if let d = disk {
            set(.disk, String(format: tr("%@ от %@ свободни", "%@ of %@ free"), diskText(d.free), diskText(d.total)))
            set(.diskRead, d.readPerSecond.map(speedText) ?? "…")   // "…" until there are two samples
            set(.diskWrite, d.writePerSecond.map(speedText) ?? "…")
        }
        set(.network, network.map { "↓ \(speedText($0.downPerSecond))   ↑ \(speedText($0.upPerSecond))" } ?? "…")
        let cleaner = RAMCleaner.shared
        freeRAMItem.isEnabled = !cleaner.isRunning
        if cleaner.isRunning {
            freeRAMItem.title = tr("Освобождаване…", "Freeing…")
        } else if let freed = cleaner.lastFreed, freed > 0 {
            freeRAMItem.title = tr("Освободи RAM (последно: ", "Free up RAM (last time: ") + memoryText(UInt64(freed)) + ")"
        } else {
            freeRAMItem.title = tr("Освободи RAM", "Free up RAM")
        }
        if let p = power {
            set(.system, watts(p.system))
            set(.cpu, watts(p.cpu))
            set(.gpu, watts(p.gpu))
            set(.other, watts(p.other))
            set(.adapter, p.adapter < 0.3 ? tr("не е включено", "not connected") : watts(p.adapter))
            set(.battery, batteryText(p.battery))
        }
    }

    private func batteryText(_ battery: Double?) -> String {
        guard let battery else { return tr("няма", "none") }
        if battery > 0.1 { return tr("зарежда с ", "charging at ") + watts(battery) }
        if battery < -0.1 { return tr("дава ", "giving ") + watts(-battery) }
        return tr("в покой", "idle")
    }

    /// An info line. It has no action, so it can't be clicked.
    private func add(_ row: Row, indent: Int = 0) {
        let item = NSMenuItem(title: label(row), action: nil, keyEquivalent: "")
        item.indentationLevel = indent
        rows[row] = item
        menu.addItem(item)
    }

    /// Label on the left, value aligned right.
    private func set(_ row: Row, _ value: String, label custom: String? = nil) {
        let label = custom ?? label(row)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
        let text = NSMutableAttributedString(string: "\(label)\t\(value)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,   // explicit, or AppKit grays out unclickable lines
            .paragraphStyle: style,
        ])
        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                          range: NSRange(location: 0, length: (label as NSString).length))
        rows[row]?.attributedTitle = text
    }
}
