import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, disk, network, energy, temperature, battery, settings
    var id: Self { self }

    /// The sidebar: everything except Battery on Macs without one.
    static var visible: [Page] { allCases.filter { $0 != .battery || BatteryModel.hasBattery } }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .disk: tr("Диск", "Disk")
        case .network: tr("Мрежа", "Network")
        case .energy: tr("Енергия", "Energy")
        case .temperature: tr("Температури", "Temperatures")
        case .battery: tr("Батерия", "Battery")
        case .settings: tr("Настройки", "Settings")
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.grid.3x3.square"
        case .ram: "memorychip"
        case .disk: "internaldrive"
        case .network: "wifi"
        case .energy: "bolt"
        case .temperature: "thermometer.medium"
        case .battery: "battery.75percent"
        case .settings: "gearshape"
        }
    }
}

/// What the window shows. Lives only while the window is open.
final class WindowModel: ObservableObject {
    /// Starts on the page you looked at last time, and remembers each switch.
    @Published var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "lastPage") ?? "") ?? .ram {
        didSet { if let page { UserDefaults.standard.set(page.rawValue, forKey: "lastPage") } }
    }
    let cpu = CPUModel()
    let gpu = GPUModel()
    let ram = RAMModel()
    let disk = DiskModel()
    let network = NetworkModel()
    let energy = EnergyModel()
    let temperature = TemperatureModel()
    let battery = BatteryModel()
}

/// The app's own window. Built when opened and thrown away when closed,
/// so it costs nothing while you only use the menu bar.
final class AppWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: WindowModel?

    /// Brings the window to the front. With a page, switches to it ("Settings…" in the menu);
    /// without one, stays wherever you were.
    func show(_ page: Page? = nil) {
        if window == nil {
            let model = WindowModel()
            let window = NSWindow(contentViewController: NSHostingController(rootView: AppWindowView(model: model)))
            window.title = "MacGlance"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            // No title strip: on macOS 26+ its edge did not line up with the glass sidebar.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.model = model
        }
        if let page { model?.page = page }
        NSApp.setActivationPolicy(.regular)   // Dock icon and ⌘-Tab while the window is open, like a normal app
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cpu.stop()
        model?.gpu.stop()
        model?.ram.stop()
        model?.disk.stop()
        model?.network.stop()
        model?.energy.stop()
        model?.temperature.stop()
        model?.battery.stop()
        model = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)   // back to living only in the menu bar
    }
}

struct AppWindowView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var settings = Settings.shared   // redraws everything when the language changes

    var body: some View {
        NavigationSplitView {
            List(Page.visible, selection: $model.page) { page in
                Label(page.title, systemImage: page.icon)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch model.page ?? .ram {
            case .cpu: CPUView(model: model.cpu)
            case .gpu: GPUView(model: model.gpu)
            case .ram: RAMView(model: model.ram)
            case .disk: DiskView(model: model.disk)
            case .network: NetworkView(model: model.network)
            case .energy: EnergyView(model: model.energy)
            case .temperature: TemperatureView(model: model.temperature)
            case .battery: BatteryView(model: model.battery)
            case .settings: SettingsView()
            }
        }
        .frame(width: 720, height: 600)
    }
}
