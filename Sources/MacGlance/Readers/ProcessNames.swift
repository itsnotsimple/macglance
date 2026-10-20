import AppKit

/// Names for the per-app lists and charts.
enum ProcessNames {
    /// The app a process belongs to: its bundle id and name, or a background process's own name.
    /// `fallback` is for an owner that has already ended.
    static func identify(owner: pid_t, fallback: String) -> (key: String, name: String) {
        let app = NSRunningApplication(processIdentifier: owner)
        let ownerName = Processes.name(owner)
        let name = app?.localizedName ?? (ownerName.isEmpty ? fallback : ownerName)
        return (app?.bundleIdentifier ?? name, name)
    }

    /// macOS's background processes in words, with the icon of the app they work for;
    /// apps and anything unknown keep their own name.
    static func label(key: String, name: String) -> (name: String, icon: String?) {
        let candidates = [key, name, key.components(separatedBy: ".").last ?? key]
        for (needles, bg, en, icon) in known
        where needles.contains(where: { needle in candidates.contains { $0 == needle || ($0.hasPrefix(needle) && needle.count > 4) } }) {
            return (tr(bg, en), icon)
        }
        return (name, key.contains(".") ? key : nil)   // an app: its bundle id gives the icon
    }

    private static let known: [([String], String, String, String?)] = [
        (["IMDPersistenceAgent", "imagent"], "Съобщения", "Messages", "com.apple.MobileSMS"),
        (["identityservicesd"], "iMessage и FaceTime", "iMessage and FaceTime", "com.apple.FaceTime"),
        (["corespotlightd", "spotlightknowledge", "mdworker", "mdbulkimport", "mds_stores", "parsecd"],
         "Spotlight (индекс за търсене)", "Spotlight (search index)", "com.apple.Spotlight"),
        (["appstoreagent", "storedownloadd", "storeassetd", "appstorecomponentsd"], "App Store", "App Store", "com.apple.AppStore"),
        (["photolibraryd", "photoanalysisd", "mediaanalysisd", "cloudphotod"], "Снимки", "Photos", "com.apple.Photos"),
        (["com.apple.Safari.SafeBrowsing"], "Safari (Safe Browsing)", "Safari (Safe Browsing)", "com.apple.Safari"),
        (["AMPLibraryAgent", "AMPArtworkAgent"], "Музика", "Music", "com.apple.Music"),
        (["calaccessd"], "Календар", "Calendar", "com.apple.iCal"),
        (["contactsd", "AddressBookSourceSync"], "Контакти", "Contacts", "com.apple.AddressBook"),
        (["remindd"], "Напомняния", "Reminders", "com.apple.reminders"),
        (["cloudd", "bird", "fileproviderd"], "iCloud", "iCloud", nil),
        (["chronod"], "Уиджети", "Widgets", nil),
        (["duetexpertd", "suggestd"], "Предложения на Siri", "Siri Suggestions", nil),
        (["knowledge-agent", "BiomeAgent", "biomesyncd"], "История на ползването (Screen Time, Siri)", "Usage history (Screen Time, Siri)", nil),
        (["intelligenceplatformd", "intelligenceflowd", "generativeexperiencesd"], "Apple Intelligence", "Apple Intelligence", nil),
        (["WindowServer"], "Екранът (WindowServer)", "The screen (WindowServer)", nil),
        (["kernel_task"], "Ядрото на macOS", "macOS kernel", nil),
        (["lsd"], "Списък с приложенията на macOS (lsd)", "macOS's list of apps (lsd)", nil),
        (["cfprefsd"], "Настройки на приложенията (cfprefsd)", "App settings (cfprefsd)", nil),
        (["nsurlsessiond"], "Изтегляния на заден план", "Background downloads", nil),
    ]
}
