import AppKit
import CryptoKit

/// Updates from GitHub Releases. Checks once a day (and on demand); when a newer version is out
/// it downloads it, checks its signature, swaps the app in place and restarts.
///
/// Every release zip is signed with a private key that never leaves the developer's Mac
/// (~/.config/macglance/update-signing-key). The app only installs a zip whose signature matches
/// the public key below, so even a hijacked GitHub account couldn't push a fake update.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "itsnotsimple/macglance"
    private static let publicKey = "AVkfDJ81PlHw5G/PYlk78xo6ilAQCQDPng7N/ljzK/A="

    struct Release {
        let version: String
        let notes: String
        let zip: URL
        let signature: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, noReleases, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private let defaults = UserDefaults.standard

    // MARK: - Checking

    /// Called from the menu bar's tick; checks at most once a day, if automatic checks are on.
    func checkIfDue() {
        guard Settings.shared.autoUpdateCheck, state != .checking, state != .downloading, state != .installing else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86400 else { return }
        check()
    }

    func check() {
        state = .checking
        defaults.set(Date(), forKey: "lastUpdateCheck")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(Self.parse)
            DispatchQueue.main.async { self.finishCheck(release: release, status: status, error: error) }
        }.resume()
    }

    private func finishCheck(release: Release?, status: Int, error: Error?) {
        if status == 404 { state = .noReleases; return }   // no repository or no release yet
        guard let release else {
            state = .failed(error?.localizedDescription ?? tr("GitHub не отговори", "GitHub didn't answer"))
            return
        }
        guard Self.isNewer(release.version, than: currentVersion) else {
            available = nil
            state = .upToDate
            return
        }
        let isNew = available?.version != release.version
        available = release
        state = .idle
        if isNew, defaults.string(forKey: "notifiedUpdate") != release.version {   // one notification per version
            defaults.set(release.version, forKey: "notifiedUpdate")
            Notifier.shared.post(title: tr("Има нова версия на MacGlance", "A new version of MacGlance is out"),
                                 body: tr("Версия \(release.version). Отвори MacGlance → Настройки, за да обновиш.",
                                          "Version \(release.version). Open MacGlance → Settings to update."))
        }
    }

    /// The GitHub API's "latest release": tag "v0.24", notes, and the .zip and .zip.sig files.
    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ suffix: String) -> URL? {
            assets.lazy.compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(suffix),
                      let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                      url.scheme == "https", url.host?.hasSuffix("github.com") == true else { return nil }
                return url
            }.first
        }
        guard let zip = asset(".zip"), let signature = asset(".zip.sig") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", zip: zip, signature: signature)
    }

    /// "0.24" > "0.9", compared number by number.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func install() {
        guard let release = available else { return }
        state = .downloading
        Task {
            do {
                let zipData = try await Self.download(release.zip)
                let signatureText = String(decoding: try await Self.download(release.signature), as: UTF8.self)
                try Self.verify(zipData, signature: signatureText)
                await MainActor.run { self.state = .installing }
                let newApp = try Self.unpack(zipData, expecting: release.version)
                try await MainActor.run { try self.replaceAndRelaunch(with: newApp) }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(tr("Свалянето не успя", "The download failed"))
        }
        return data
    }

    /// Refuses anything not signed with our private key.
    private static func verify(_ data: Data, signature: String) throws {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: data) else {
            throw UpdateError(tr("Подписът на ъпдейта не съвпада: не е инсталиран", "The update's signature doesn't match: not installed"))
        }
    }

    /// Unzips into a temporary folder and checks it's really MacGlance, at the promised version.
    private static func unpack(_ zip: Data, expecting version: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacGlance-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zipFile = folder.appendingPathComponent("update.zip")
        try zip.write(to: zipFile)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipFile.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = folder.appendingPathComponent("MacGlance.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard ditto.terminationStatus == 0,
              info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(tr("Ъпдейтът е повреден", "The update is damaged"))
        }
        return app
    }

    /// Swaps the app on disk (the running copy keeps working from memory), then starts the new
    /// one as soon as this one has quit and saved its history.
    private func replaceAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                              current.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}
