import AppKit

struct AppMemory: Identifiable {
    let app: NSRunningApplication
    let bytes: UInt64
    var id: pid_t { app.processIdentifier }
}

/// Which apps hold the most RAM, counted like the "Memory" column in Activity Monitor.
/// Helper processes (Safari's web pages, Electron renderers...) are added to the app they belong to.
final class AppMemoryReader {
    func top(_ count: Int) -> [AppMemory] {
        var bytesByOwner: [pid_t: UInt64] = [:]
        for pid in Processes.all() {
            guard let usage = Processes.usage(pid) else { continue }   // system processes need root, that's fine
            bytesByOwner[Processes.owner(of: pid), default: 0] += usage.ri_phys_footprint
        }

        let me = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != me && isQuittable($0) }
            .map { AppMemory(app: $0, bytes: bytesByOwner[$0.processIdentifier] ?? 0) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(count)
            .map { $0 }
    }
}

/// Normal apps, plus menu bar apps from other companies (AdGuard, Logi...).
/// Apple's own background parts (Siri, Notification Centre) and Finder are left out:
/// macOS would just start them again.
func isQuittable(_ app: NSRunningApplication) -> Bool {
    let id = app.bundleIdentifier ?? ""
    switch app.activationPolicy {
    case .regular: return id != "com.apple.finder"
    case .accessory: return !id.hasPrefix("com.apple.")
    default: return false
    }
}
