import AppKit

struct SleepTip: Identifiable {
    let kind: BatteryTip.Kind
    let text: String
    let settings: String?   // a System Settings pane to open, if there's a switch for it
    var id: String { text }
}

/// Advice from the last week of sleep: only about what actually woke this Mac often,
/// with where to switch it off if you want to. All of these are optional.
enum SleepTips {
    static func tips(for sessions: [SleepSession]) -> [SleepTip] {
        var wakers: [String: Int] = [:]
        var causes: [String: Int] = [:]
        for session in sessions {
            for (key, count) in session.wakers { wakers[key, default: 0] += count }
            for (key, count) in session.causes { causes[key, default: 0] += count }
        }
        func count(_ needles: String...) -> Int {
            wakers.filter { key, _ in needles.contains { key.contains($0) } }.values.reduce(0, +)
        }
        var tips: [SleepTip] = []

        let intelligence = count("intelligenceflow", "GenerativeFunctions", "imageplaygroundd")
        if intelligence >= 20 {
            if appleIntelligenceOn == false {
                // Turned off, and they still run: say so, so nobody hunts for a switch that isn't there.
                tips.append(.init(kind: .info, text: tr(
                    "Задачи на Apple Intelligence са будили Мака \(intelligence) пъти тази седмица, въпреки че при теб то е изключено: macOS пак проверява моделите и списъка с действия на Siri. За това няма копче, а всяко събуждане е за секунди. Няма какво да правиш.",
                    "Apple Intelligence tasks woke the Mac \(intelligence) times this week, even though you have it turned off: macOS still checks its models and Siri's list of app actions. There's no switch for that, and each wake lasts seconds. Nothing to do."),
                    settings: nil))
            } else {
                tips.append(.init(kind: .info, text: tr(
                    "Apple Intelligence е будило Мака \(intelligence) пъти тази седмица, за да обновява моделите си и списъка с действия на Siri. Ако не го ползваш, можеш да го изключиш в настройките на Siri.",
                    "Apple Intelligence woke the Mac \(intelligence) times this week to update its models and Siri's list of app actions. If you don't use it, you can turn it off in Siri's settings."),
                    settings: "com.apple.Siri-Settings.extension"))
            }
        }
        let screenTime = count("ScreenTimeAgent")
        if screenTime >= 20 {
            tips.append(.init(kind: .info, text: tr(
                "Screen Time е будило Мака \(screenTime) пъти, за да подрежда историята си. Ако не го гледаш, изключи „App & Website Activity“ в Screen Time.",
                "Screen Time woke the Mac \(screenTime) times to tidy its history. If you don't look at it, turn off “App & Website Activity” in Screen Time."),
                settings: "com.apple.Screen-Time-Settings.extension"))
        }
        let notifications = causes["notification"] ?? 0
        if notifications >= 10 {
            tips.append(.init(kind: .info, text: tr(
                "Известия са светвали екрана \(notifications) пъти, докато спи. Ако не искаш, в Notifications изключи „Allow notifications when the display is sleeping“.",
                "Notifications lit the screen \(notifications) times while it slept. If you don't want that, turn off “Allow notifications when the display is sleeping” in Notifications."),
                settings: "com.apple.Notifications-Settings.extension"))
        }
        let calendar = count("calaccessd")
        if calendar >= 10 {
            tips.append(.init(kind: .info, text: tr(
                "Календарът е будил Мака \(calendar) пъти, за да смята „кога да тръгнеш“. Ако не ти трябва: Calendar → Settings → Alerts → изключи „Time to leave“.",
                "Calendar woke the Mac \(calendar) times to work out “time to leave”. If you don't need it: Calendar → Settings → Alerts → turn off “Time to leave”."),
                settings: nil))
        }
        let network = causes["network"] ?? 0
        if network >= 30 {
            tips.append(.init(kind: .info, text: tr(
                "Мрежата е будила Мака \(network) пъти: поща, съобщения и Find My пазят връзката си. За път в чанта: изключи Wi-Fi, преди да затвориш капака, и няма да го будят.",
                "The network woke the Mac \(network) times: mail, messages and Find My keep their connections. For a trip in a bag: turn Wi-Fi off before closing the lid and they won't."),
                settings: nil))
        }
        let charging = count("com.apple.obc")
        if charging >= 10 {
            tips.append(.init(kind: .good, text: tr(
                "Оптимизираното зареждане се е събуждало \(charging) пъти: то държи батерията на 80% и я пази. Остави го.",
                "Optimized Battery Charging woke up \(charging) times: it holds the battery at 80% and protects it. Keep it."),
                settings: nil))
        }
        return tips
    }

    /// Whether Apple Intelligence is turned on: macOS keeps the choice under a number that changes
    /// between versions (1 = on). nil if there's nothing there (an older macOS, or never asked).
    static var appleIntelligenceOn: Bool? {
        let domain = "com.apple.CloudSubscriptionFeatures.optIn" as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else { return nil }
        let choices = keys.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .compactMap { CFPreferencesCopyAppValue($0 as CFString, domain) as? Bool }
        return choices.isEmpty ? nil : choices.contains(true)
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }
}
