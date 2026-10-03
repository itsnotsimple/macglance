import AppKit
import SwiftUI

enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case cpu, gpu, ram, power, network, temperature, battery
    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .power: tr("Мощност", "Power")
        case .network: tr("Мрежа", "Network")
        case .temperature: tr("Температура", "Temperature")
        case .battery: tr("Батерия", "Battery")
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.grid.3x3.square"
        case .ram: "memorychip"
        case .power: "bolt"
        case .network: "wifi"
        case .temperature: "thermometer.medium"
        case .battery: "battery.75percent"
        }
    }
}

enum WidgetSize: String, Codable, CaseIterable {
    case small, wide

    /// The same sizes as Apple's small and medium widgets.
    var points: CGSize { self == .small ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158) }
    var title: String { self == .small ? tr("Малък", "Small") : tr("Широк", "Wide") }
}

struct WidgetConfig: Codable {
    var size: WidgetSize
    var origin: CGPoint?   // bottom-left corner on screen; nil = place it automatically
}

/// The latest numbers for the widgets, filled in by the menu bar's tick.
final class WidgetData: ObservableObject {
    @Published var cpu: CPULoad?
    @Published var gpu: GPUStats?
    @Published var memory: MemoryUsage?
    @Published var power: PowerUsage?
    @Published var network: NetworkUsage?
    @Published var temperatures: Temperatures?
    @Published var battery: BatteryInfo?
}

/// Widgets that live on the desktop: borderless cards above the wallpaper and below every
/// window, on all Spaces. Drag them anywhere; right-click for size, remove, open MacGlance.
final class DesktopWidgets: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DesktopWidgets()

    @Published private(set) var configs: [WidgetKind: WidgetConfig] = [:]   // the widgets that are on
    let data = WidgetData()
    var openApp: () -> Void = {}   // set by AppDelegate
    private var windows: [WidgetKind: NSWindow] = [:]
    private var lastRefresh = Date.distantPast

    private override init() {
        super.init()
        if let saved = UserDefaults.standard.data(forKey: "widgets"),
           let decoded = try? JSONDecoder().decode([String: WidgetConfig].self, from: saved) {
            configs = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in WidgetKind(rawValue: key).map { ($0, value) } })
        }
    }

    /// At launch: put the saved widgets back on the desktop.
    func showAll() {
        for kind in WidgetKind.allCases where configs[kind] != nil { open(kind) }
    }

    /// Asked once per tick. Visible widgets refresh every tick; covered ones once every 30 s,
    /// so they're never far behind when the desktop shows (or if macOS misreports visibility).
    func shouldRefresh() -> Bool {
        guard !windows.isEmpty else { return false }
        let anyVisible = windows.values.contains { $0.occlusionState.contains(.visible) }
        guard anyVisible || Date().timeIntervalSince(lastRefresh) >= 30 else { return false }
        lastRefresh = Date()
        return true
    }

    func isOn(_ kind: WidgetKind) -> Bool { configs[kind] != nil }

    func setOn(_ kind: WidgetKind, _ on: Bool) {
        if on {
            guard configs[kind] == nil else { return }
            configs[kind] = WidgetConfig(size: .small, origin: nil)
            open(kind)
        } else {
            configs[kind] = nil
            windows[kind]?.close()
            windows[kind] = nil
        }
        save()
    }

    func setSize(_ kind: WidgetKind, _ size: WidgetSize) {
        guard configs[kind] != nil, configs[kind]?.size != size else { return }
        configs[kind]?.size = size
        windows[kind]?.close()   // rebuilt at the new size, same corner
        windows[kind] = nil
        open(kind)
        save()
    }

    // MARK: - Windows

    private func open(_ kind: WidgetKind) {
        guard let config = configs[kind] else { return }
        let size = config.size.points
        let origin = config.origin.flatMap { isOnScreen($0, size) ? $0 : nil } ?? defaultOrigin(for: kind, size)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Just above the desktop icons, below every app window, like Apple's desktop widgets.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = DraggableHostingView(rootView: WidgetCard(kind: kind, size: config.size, data: data, widgets: self))
        window.delegate = self
        window.orderFront(nil)
        windows[kind] = window
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        configs[kind]?.origin = window.frame.origin
        save()
    }

    private func isOnScreen(_ origin: CGPoint, _ size: CGSize) -> Bool {
        let frame = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }   // its monitor may be gone
    }

    /// New widgets line up from the top-right corner of the main screen, one under the other.
    private func defaultOrigin(for kind: WidgetKind, _ size: CGSize) -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let slot = WidgetKind.allCases.firstIndex(of: kind) ?? 0
        let top = screen.maxY - 24 - CGFloat(slot % 4) * (158 + 16)
        let column = CGFloat(slot / 4) * (338 + 16)
        return CGPoint(x: screen.maxX - 24 - size.width - column, y: top - size.height)
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        if let encoded = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(encoded, forKey: "widgets") }
    }
}

/// SwiftUI content that lets a click-and-drag anywhere move the borderless window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
