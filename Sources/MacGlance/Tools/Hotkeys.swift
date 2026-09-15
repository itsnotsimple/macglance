import AppKit
import Carbon

/// A key plus modifiers, stored with Carbon's numbers (what RegisterEventHotKey takes).
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// "⌃⌥⌘M", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The key's letter on a Latin layout, so it reads "M" even while typing in Cyrillic.
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        layout.withUnsafeBytes { raw in
            guard let keyboard = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            UCKeyTranslate(keyboard, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Global keyboard shortcuts the user records in Settings. They work in any app, without the
/// Accessibility permission, through Carbon's hot keys (old, but what Mac apps still use for this).
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()

    enum Action: String, CaseIterable, Identifiable {
        case openWindow, freeRAM, showMenu
        var id: Self { self }

        var title: String {
            switch self {
            case .openWindow: tr("Отвори MacGlance", "Open MacGlance")
            case .freeRAM: tr("Освободи RAM", "Free up RAM")
            case .showMenu: tr("Покажи менюто горе", "Show the menu bar menu")
            }
        }
    }

    @Published private(set) var shortcuts: [Action: Shortcut] = [:]
    @Published private(set) var recording: Action?
    @Published private(set) var taken: Set<Action> = []   // macOS refused: another app already uses it
    var handlers: [Action: () -> Void] = [:]              // set by AppDelegate

    private var registered: [Action: EventHotKeyRef] = [:]
    private var monitor: Any?
    private let signature: OSType = 0x4D47_6C63   // "MGlc", marks our hot keys

    private init() {
        if let data = UserDefaults.standard.data(forKey: "hotkeys"),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Action(rawValue: key).map { ($0, value) } })
        }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = Action.allCases[Int(id.id)]
            DispatchQueue.main.async { HotkeyCenter.shared.handlers[action]?() }
            return noErr
        }, 1, &pressed, nil, nil)
        registerAll()
    }

    // MARK: - Recording

    /// Listens for the next key press in our window. Esc cancels, ⌫ clears.
    func startRecording(_ action: Action) {
        stopRecording()
        recording = action
        unregisterAll()   // so pressing an existing shortcut records it instead of running it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil   // swallow the key
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            registerAll()
        }
    }

    func clear(_ action: Action) {
        shortcuts[action] = nil
        save()
        unregisterAll()
        registerAll()
    }

    private func record(_ event: NSEvent) {
        guard let action = recording else { return }
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 53:   // Esc
            stopRecording()
        case 51 where plain, 117 where plain:   // ⌫ / ⌦ on their own
            shortcuts[action] = nil
            save()
            stopRecording()
        default:
            let flags = event.modifierFlags
            // A plain letter (or ⇧ + letter) would block normal typing everywhere.
            guard !plain else {
                NSSound.beep()
                return
            }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            for (other, existing) in shortcuts where existing == shortcut && other != action { shortcuts[other] = nil }   // one action per key
            shortcuts[action] = shortcut
            save()
            stopRecording()
        }
    }

    // MARK: - Registering with macOS

    private func registerAll() {
        var refused: Set<Action> = []
        for (index, action) in Action.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { registered[action] = reference } else { refused.insert(action) }
        }
        taken = refused
    }

    private func unregisterAll() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered = [:]
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: "hotkeys") }
    }
}
