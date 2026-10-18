import AppKit

/// Clears apps' caches in ~/Library/Caches. Only folders that clearly belong to an installed app
/// are offered: macOS's own caches, developer tool caches (pip, Homebrew, npm…) and anything
/// unknown are left alone. Apps rebuild their cache by themselves, so nothing personal is lost;
/// caches of apps that are open are skipped so they don't break while running.
final class CacheCleaner: ObservableObject {
    static let shared = CacheCleaner()

    struct Entry: Identifiable {
        let id: String          // the folder, relative to ~/Library/Caches ("com.spotify.client", "Google/Chrome")
        let bundleID: String
        let name: String        // the app's name
        let icon: NSImage
        let bytes: Int64
        var isRunning: Bool
    }

    enum State { case idle, scanning, cleaning }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var scanned = false
    @Published private(set) var lastFreed: Int64?
    @Published var selected: Set<String> = []
    var notify: (_ title: String, _ body: String) -> Void = { Notifier.shared.post(title: $0, body: $1) }   // a test swaps it

    /// Caches whose folder isn't named after the app. Checked on this Mac.
    private static let knownFolders = [
        "Google/Chrome": "com.google.Chrome",
        "Steam": "com.valvesoftware.steam",
    ]

    private let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)

    var selectedBytes: Int64 {
        entries.filter { selected.contains($0.id) && !$0.isRunning }.map(\.bytes).reduce(0, +)
    }

    // MARK: - Scanning

    func scan() {
        guard state != .scanning, state != .cleaning else { return }
        state = .scanning
        DispatchQueue.global(qos: .background).async {   // lowest priority: E-cores, no heat
            let found = self.findAppCaches()
            DispatchQueue.main.async {
                self.entries = found
                self.selected = Set(found.filter { !$0.isRunning }.map(\.id))   // everything that can be cleared, pre-ticked
                self.scanned = true
                self.state = .idle
            }
        }
    }

    private func findAppCaches() -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var candidates: [(folder: String, bundleID: String)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: caches.path)) ?? [] {
            if name.hasPrefix("com.apple.") || name == me { continue }   // macOS's own, and ours
            candidates.append((name, name))                              // usually named after the app's bundle id
        }
        candidates += Self.knownFolders.map { ($0.key, $0.value) }

        return candidates.compactMap { folder, bundleID -> Entry? in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }   // not an app: skip
            let url = caches.appendingPathComponent(folder, isDirectory: true)
            let bytes = Self.size(of: url)
            guard bytes >= 1_000_000 else { return nil }   // under 1 MB isn't worth a row
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            return Entry(id: folder, bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: app.path),
                         bytes: bytes, isRunning: Self.isRunning(bundleID))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Space the files really take on disk. Symbolic links are not followed.
    private static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Cleaning

    /// Empties the selected cache folders (the folders themselves stay, apps expect them).
    func clean() {
        let chosen = entries.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, state == .idle else { return }
        state = .cleaning
        DispatchQueue.global(qos: .background).async {   // lowest priority: E-cores, no heat
            var freed: Int64 = 0
            for entry in chosen where !Self.isRunning(entry.bundleID) {   // it may have been opened since the scan
                let folder = self.caches.appendingPathComponent(entry.id, isDirectory: true)
                guard Self.isInsideCaches(folder, self.caches) else { continue }
                for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: item)   // files in use or protected stay; that's fine
                }
                freed += max(0, entry.bytes - Self.size(of: folder))   // the size from the scan, so it's measured once
            }
            DispatchQueue.main.async {
                self.lastFreed = freed
                self.state = .idle
                self.notify(tr("Кешът е изчистен", "Cache cleared"), tr("Освободени ", "Freed ") + bytesText(Double(freed)))
                self.scan()   // fresh sizes
            }
        }
    }

    /// A last safety check: never touch anything outside ~/Library/Caches, or Caches itself.
    private static func isInsideCaches(_ folder: URL, _ caches: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let root = caches.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") && path != root
    }
}
