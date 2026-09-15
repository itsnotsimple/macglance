import AppKit
import ServiceManagement

/// Starting MacGlance when you log in (System Settings → General → Login Items).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MacGlance: launch at login failed: \(error)")
            }
            if SMAppService.mainApp.status == .requiresApproval {   // the user switched it off in Settings before
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    /// True when macOS started us at login: then we stay quietly in the menu bar, no window.
    /// Only valid during applicationDidFinishLaunching, while the launch event is being handled.
    static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
