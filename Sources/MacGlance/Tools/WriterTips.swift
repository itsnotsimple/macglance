import AppKit

/// For the "Who writes the most" list: a line on what each writer is and whether it's normal,
/// and what you can do about an installed app (quit it, show it in Finder, move it to the Trash).
enum WriterTips {
    /// What it is, in a few words. nil for anything without a clear, honest answer.
    static func note(key: String) -> String? {
        let key = key.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { key.contains($0) } }

        if has("com.brave", "com.google.chrome", "com.apple.safari", "org.mozilla", "company.thebrowser",
               "com.microsoft.edge", "com.operasoftware", "com.vivaldi") {
            return tr("Кешира видео и страници. Нормално при YouTube, Twitch и много табове.",
                      "Caches video and pages. Normal with YouTube, Twitch and many tabs.")
        }
        if has("corespotlightd", "spotlightknowledge", "mdworker", "mds_stores", "mdbulkimport") {
            return tr("Обновява индекса за търсене. Нормално след инсталации, ъпдейти и много нови файлове.",
                      "Updates the search index. Normal after installs, updates and lots of new files.")
        }
        if has("cloudd", "fileproviderd", "com.microsoft.onedrive", "com.getdropbox", "com.google.drivefs") || key == "bird" {
            return tr("Синхронизира файлове с облака. Пише, докато качва или тегли.",
                      "Syncs files with the cloud. Writes while it uploads or downloads.")
        }
        if has("photoanalysisd", "photolibraryd", "mediaanalysisd", "cloudphotod") {
            return tr("Анализира снимките (лица, обекти). Временно, после спира.",
                      "Analyses your photos (faces, objects). Temporary, then it stops.")
        }
        if key == "lsd" {
            return tr("Обновява списъка с приложения след инсталиране или ъпдейт. Нормално.",
                      "Updates the list of apps after an install or update. Normal.")
        }
        if has("knowledge-agent", "biomeagent", "biomesyncd") {
            return tr("История за Screen Time и Siri. Обикновено малко.",
                      "History for Screen Time and Siri. Usually little.")
        }
        if has("com.anthropic") || key == "claude" {
            return tr("Включва всичко, което Claude Code пуска (билдове, скриптове), и виртуалната му машина. Големи дни: билдове или ъпдейт на машината (~10 GB).",
                      "Includes everything Claude Code runs (builds, scripts) and its virtual machine. Big days: builds or a machine update (~10 GB).")
        }
        if has("imdpersistenceagent", "imagent") {
            return tr("Записва съобщения и прикачени файлове от iMessage. Пише всеки ден при голяма история в iCloud.",
                      "Saves iMessage messages and attachments. Writes daily with a big history in iCloud.")
        }
        if has("com.valvesoftware", "com.epicgames", "battle.net", "com.roblox", "appstoreagent", "storedownloadd", "softwareupdate") {
            return tr("Тегли и инсталира игри или ъпдейти. Пише много, но само докато трае.",
                      "Downloads and installs games or updates. Writes a lot, but only while it lasts.")
        }
        if has("com.spotify", "com.apple.music") {
            return tr("Кешира музика, за да пуска по-бързо.", "Caches music so it starts faster.")
        }
        if has("com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop", "antigravity", "com.docker")
            || ["swift", "swift-build", "swift-frontend", "clang", "ld", "node", "python", "python3", "java", "cargo", "rustc"].contains(key) {
            return tr("Билдове, пакети и индексиране при програмиране. Нормално, докато работиш.",
                      "Builds, packages and indexing while you code. Normal while you work.")
        }
        if has("ru.keepcoder.telegram", "org.telegram", "com.hnc.discord", "com.tinyspeck.slackmacgap", "whatsapp") {
            return tr("Кешира снимки и видео от чатовете.", "Caches photos and videos from your chats.")
        }
        if has("com.malwarebytes") {
            return tr("Проверява файловете в реално време. На Mac рядко е нужно.",
                      "Checks files in real time. Rarely needed on a Mac.")
        }
        return nil
    }

    /// The running app behind a row, if it has a window you could quit.
    static func running(_ key: String) -> NSRunningApplication? {
        guard key.contains("."), key != Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: key).first { $0.activationPolicy == .regular }
    }

    /// Where an installed app lives, if it's one you installed yourself (not part of macOS, not MacGlance).
    static func installed(_ key: String) -> URL? {
        guard key.contains("."), key != Bundle.main.bundleIdentifier, !key.hasPrefix("com.apple."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key),
              !url.path.hasPrefix("/System/") else { return nil }
        return url
    }

    /// Quits the app (like ⌘Q, so it can still ask to save) and moves it to the Trash, where it can be
    /// put back from. Gives up if it hasn't quit within 10 seconds, e.g. while it asks about unsaved work.
    static func quitAndTrash(key: String, url: URL, done: @escaping (Bool) -> Void) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: key)
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        func attempt() {
            if apps.contains(where: { !$0.isTerminated }) {
                guard Date() < deadline else { return done(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt() }
                return
            }
            NSWorkspace.shared.recycle([url]) { _, error in DispatchQueue.main.async { done(error == nil) } }
        }
        attempt()
    }
}
