import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = Settings.shared
    private let appWindow = AppWindow()
    private lazy var infoMenu = InfoMenu(onOpen: { [weak self] in self?.tick() },
                                         openSettings: { [weak self] in self?.appWindow.show(.settings) })
    private var settingsObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private var terminationSignal: DispatchSourceSignal?

    private let cpu = CPUReader()
    private let gpu = GPUReader()
    private let memory = MemoryReader()
    private let power = PowerReader()
    private let disk = DiskReader()
    private let network = NetworkReader()
    private let temperature = TemperatureReader()
    private let energy = ProcessEnergyReader()
    private let store = MetricStore.shared
    private var lastTemperatureRecord = Date.distantPast
    private var lastSSDCheck = Date.distantPast
    private var timer: Timer?
    private var shownItems: [BarItem]?   // what the compact image currently shows

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = "CPU –"
        statusItem.menu = infoMenu.menu
        NSApp.mainMenu = makeMainMenu()

        // a new version found: put "Update to …" on top of the menu
        updateObserver = Updater.shared.$available.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.infoMenu.rebuild()
        }

        // receive(on:) delivers after the change is stored, not before
        settingsObserver = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.settingsChanged()
        }

        // `kill` / pkill (installing an update) sends SIGTERM, which would end the app without
        // applicationWillTerminate: catch it and quit normally, so the history gets saved first.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination

        UserDefaults.standard.removeObject(forKey: "widgets")   // settings of the old desktop cards (v0.27)

        HotkeyCenter.shared.handlers = [
            .openWindow: { [weak self] in self?.appWindow.show() },
            .freeRAM: { RAMCleaner.shared.run() },   // the result comes as a notification, if those are on
            .showMenu: { [weak self] in self?.statusItem.button?.performClick(nil) },
        ]

        _ = cpu.read()   // baseline, the first real value comes on the first tick
        startTimer()
        RAMCleaner.shared.applySchedule()

        if !LaunchAtLogin.wasLaunchedAtLogin {   // opened by hand (Finder, Spotlight): show the window
            appWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MetricStore.shared.save()   // keep the chart history and the energy log for next time
        EnergyLedger.shared.save()
        DailyTraffic.shared.save()
    }

    /// Clicking the app icon while MacGlance is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appWindow.show()   // keeps the page you were on
        return false
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: settings.interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = settings.interval / 4   // lets macOS batch our wakeups with others, saves energy
        RunLoop.main.add(timer, forMode: .common)   // .common keeps it ticking while the menu is open
        self.timer = timer
    }

    private func settingsChanged() {
        infoMenu.rebuild()                  // language may have changed
        NSApp.mainMenu = makeMainMenu()
        if timer?.timeInterval != settings.interval { startTimer() }
        RAMCleaner.shared.applySchedule()
        tick()                              // show/hide items right away
    }

    private func tick() {
        // Hidden numbers are not read at all, unless the menu is open and needs them.
        let menuOpen = infoMenu.isOpen
        let mem = settings.showRAM || menuOpen ? memory.read() : nil
        let pwr = power.read()   // always: feeds the watts chart (~1 ms)
        if let pwr {
            store.record(.power, pwr.system)
            EnergyLedger.shared.add(pwr)   // daily kWh for the electricity bill
        }
        let dsk = settings.showDisk || menuOpen ? disk.read() : nil
        let net = network.read()   // always: feeds the network charts and today's traffic (~0.1 ms)
        if let net {
            store.record(.networkDown, net.downPerSecond)
            store.record(.networkUp, net.upPerSecond)
            DailyTraffic.shared.update(net)
        }
        // Temperature history: one reading every 10 s is enough (each read is ~1.7 ms of SMC calls).
        let temperatureDue = Date().timeIntervalSince(lastTemperatureRecord) >= 10
        let temp = settings.showTemperature || menuOpen || temperatureDue ? temperature.read(cpuOnly: !menuOpen) : nil
        if temperatureDue, let hottest = temp?.cpu {
            store.record(.cpuTemperature, hottest)
            lastTemperatureRecord = Date()
        }

        // The same numbers in both looks. A reader that fails is simply left out.
        var items: [BarItem] = []   // compact: two-line blocks
        var parts: [String] = []    // text: one line
        // CPU and GPU load are always read: they feed the history charts (a few µs each).
        let cpuLoad = cpu.read()
        let load = cpuLoad?.total
        if let load { store.record(.cpu, load) }
        let gpuStats = gpu.read()
        if let gpuStats { store.record(.gpu, Double(gpuStats.load)) }
        if settings.showCPU, let load {
            let value = String(format: "%.0f%%", load)
            items.append(.labeled("CPU", value, widest: "100%"))
            parts.append("CPU " + value)
        }
        if settings.showGPU, let gpuLoad = gpuStats?.load {
            items.append(.labeled("GPU", "\(gpuLoad)%", widest: "100%"))
            parts.append("GPU \(gpuLoad)%")
        }
        if settings.showRAM, let mem {
            let value = String(format: "%.0f%%", mem.usedPercent)
            items.append(.labeled("RAM", value, widest: "100%"))
            parts.append("RAM " + value)
        }
        if settings.showPower, let pwr {
            items.append(.labeled("W", wattsShort(pwr.system), widest: "88.8"))
            parts.append(watts(pwr.system))
        }
        if settings.showNetwork {   // the first sample has no speed yet: keep the place with dashes
            let down = "↓" + (net.map { speedShort($0.downPerSecond) } ?? "–")
            let up = "↑" + (net.map { speedShort($0.upPerSecond) } ?? "–")
            items.append(.pair(down, up, widest: "↓88.8M"))
            parts.append(down + " " + up)
        }
        if settings.showTemperature, let cpuTemp = temp?.cpu {
            items.append(.labeled("°C", String(format: "%.0f", cpuTemp), widest: "888"))
            parts.append(String(format: "%.0f°C", cpuTemp))
        }
        if settings.showDisk, let dsk {
            items.append(.labeled("SSD", diskShort(dsk.free), widest: "888G"))
            parts.append("SSD " + diskText(dsk.free))
        }

        showInBar(items: items, text: parts.joined(separator: "  "))
        Alerts.shared.tick()   // smart notifications; each check runs on its own slower schedule
        Updater.shared.checkIfDue()   // at most once a day

        // The SSD's write counter, every 30 minutes: it marks where each day starts for "written today".
        if Date().timeIntervalSince(lastSSDCheck) >= 1800 {
            lastSSDCheck = Date()
            _ = SSDReader().read()
        }

        WidgetPublisher.shared.tick(cpu: cpuLoad, gpu: gpuStats, memory: mem, power: pwr, network: net)   // only if widgets are placed

        let topApps = menuOpen ? energy.top(3, gpuWatts: pwr?.gpu ?? 0) : []   // scanning all processes: only when looked at
        infoMenu.update(memory: mem, power: pwr, disk: dsk, network: net, temperature: temp, topApps: topApps)
    }

    /// Redraws the menu bar only when what it shows actually changed.
    private func showInBar(items: [BarItem], text: String) {
        guard let button = statusItem.button else { return }
        if items.isEmpty {   // everything switched off: an icon keeps MacGlance clickable
            guard shownItems != [] else { return }
            shownItems = []
            button.title = ""
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "MacGlance")
        } else if settings.compactBar {
            guard items != shownItems else { return }
            shownItems = items
            button.title = ""
            button.image = StatusRenderer.image(for: items)
            button.setAccessibilityTitle(text)   // VoiceOver can't read an image
        } else {
            guard button.title != text || shownItems != nil else { return }
            shownItems = nil
            button.image = nil
            button.title = text
        }
    }

    /// The app menu at the top of the screen, only visible while the window is open.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Затвори прозореца", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Изход от MacGlance", "Quit MacGlance"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
