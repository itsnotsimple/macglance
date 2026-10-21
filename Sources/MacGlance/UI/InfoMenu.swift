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
        // No key equivalents here: one would add a shortcut column, i.e. empty space right of every value.
        let settings = NSMenuItem(title: tr("Настройки…", "Settings…"), action: #selector(settingsClicked), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: tr("Изход", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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
                rows[row]?.isHidden = false
            } else {
                set(row, "…", label: "")                          // "…" until the first measurement
                rows[row]?.isHidden = !(index == 0 && topApps.isEmpty)   // no blank rows when fewer than 3 apps
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
        let item = NSMenuItem()
        item.view = InfoRowView(label: label(row), indent: indent)
        rows[row] = item
        menu.addItem(item)
    }

    /// Label on the left, value against the right edge.
    private func set(_ row: Row, _ value: String, label custom: String? = nil) {
        (rows[row]?.view as? InfoRowView)?.show(label: custom ?? label(row), value: value)
    }
}

/// One line of numbers in the menu, laid out by MacGlance rather than by macOS. macOS leaves a different
/// amount of room right of a menu's text in each version (on some, three times the left margin); here
/// both sides get the same margin, and every value ends on the same edge, indented lines included.
private final class InfoRowView: NSView {
    private static let margin: CGFloat = 16
    private static let indentStep: CGFloat = 12
    /// The height of a normal menu line on this macOS (24 pt on recent versions, 22 on older ones).
    private static let height: CGFloat = {
        let probe = NSMenu()
        probe.addItem(withTitle: "A", action: nil, keyEquivalent: "")
        let one = probe.size.height
        probe.addItem(withTitle: "B", action: nil, keyEquivalent: "")
        let height = probe.size.height - one
        return height > 10 && height < 40 ? height : 22
    }()
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    init(label text: String, indent: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 262, height: Self.height))   // the menu's width: room for "Disk  818 GB of 995 GB free"
        autoresizingMask = [.width]   // a wider menu (a long "Free up RAM (last time: …)") keeps the value at the right margin
        for field in [label, value] {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        label.textColor = .secondaryLabelColor
        label.stringValue = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // a long app name gives way, the number doesn't
        value.textColor = .labelColor
        value.alignment = .right
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin + CGFloat(indent) * Self.indentStep),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(label text: String, value newValue: String) {
        if label.stringValue != text { label.stringValue = text }   // only what changed: no relayout every second
        if value.stringValue != newValue { value.stringValue = newValue }
    }
}
