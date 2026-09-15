import Foundation

enum Language: String {
    case bg, en
}

/// App settings, saved in UserDefaults. The window edits them, the menu bar watches them.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "showCPU") } }
    @Published var showGPU: Bool { didSet { defaults.set(showGPU, forKey: "showGPU") } }
    @Published var showRAM: Bool { didSet { defaults.set(showRAM, forKey: "showRAM") } }
    @Published var showPower: Bool { didSet { defaults.set(showPower, forKey: "showPower") } }
    @Published var showNetwork: Bool { didSet { defaults.set(showNetwork, forKey: "showNetwork") } }
    @Published var showDisk: Bool { didSet { defaults.set(showDisk, forKey: "showDisk") } }
    @Published var showTemperature: Bool { didSet { defaults.set(showTemperature, forKey: "showTemperature") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }   // seconds
    @Published var chartRange: TimeRange { didSet { defaults.set(chartRange.rawValue, forKey: "chartRange") } }   // all charts
    @Published var compactBar: Bool { didSet { defaults.set(compactBar, forKey: "compactBar") } }   // two-line blocks vs one line of text

    // Updates
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }

    // Smart notifications
    @Published var alertRunaway: Bool { didSet { defaults.set(alertRunaway, forKey: "alertRunaway") } }
    @Published var alertMemory: Bool { didSet { defaults.set(alertMemory, forKey: "alertMemory") } }
    @Published var alertCharger: Bool { didSet { defaults.set(alertCharger, forKey: "alertCharger") } }
    @Published var alertBatteryHot: Bool { didSet { defaults.set(alertBatteryHot, forKey: "alertBatteryHot") } }
    @Published var alertThermal: Bool { didSet { defaults.set(alertThermal, forKey: "alertThermal") } }

    // Electricity bill
    @Published var electricityPrice: Double { didSet { defaults.set(electricityPrice, forKey: "electricityPrice") } }   // per kWh, 0 = not set
    @Published var currency: String { didSet { defaults.set(currency, forKey: "currency") } }

    // Free up RAM
    @Published var notifyOnClean: Bool { didSet { defaults.set(notifyOnClean, forKey: "notifyOnClean") } }
    @Published var autoCleanMinutes: Int { didSet { defaults.set(autoCleanMinutes, forKey: "autoCleanMinutes") } }   // 0 = off
    @Published var autoCleanAbove: Int { didSet { defaults.set(autoCleanAbove, forKey: "autoCleanAbove") } }   // % of RAM used, 0 = any

    private init() {
        defaults.register(defaults: ["showCPU": true, "showGPU": true, "showRAM": true, "showPower": true, "interval": 2.0,
                                     "showNetwork": false, "showDisk": false, "showTemperature": false, "compactBar": true,
                                     "notifyOnClean": true, "alertRunaway": true, "alertMemory": true, "alertCharger": true, "alertBatteryHot": true, "alertThermal": true, "autoUpdateCheck": true, "electricityPrice": 0.0, "currency": "€", "autoCleanMinutes": 0, "autoCleanAbove": 70])
        // First start: Bulgarian if it is anywhere in the Mac's language list, otherwise English.
        let systemLanguage: Language = Locale.preferredLanguages.contains { $0.hasPrefix("bg") } ? .bg : .en
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? systemLanguage
        showCPU = defaults.bool(forKey: "showCPU")
        showGPU = defaults.bool(forKey: "showGPU")
        showRAM = defaults.bool(forKey: "showRAM")
        showPower = defaults.bool(forKey: "showPower")
        showNetwork = defaults.bool(forKey: "showNetwork")
        showDisk = defaults.bool(forKey: "showDisk")
        showTemperature = defaults.bool(forKey: "showTemperature")
        interval = defaults.double(forKey: "interval")
        compactBar = defaults.bool(forKey: "compactBar")
        chartRange = TimeRange(rawValue: defaults.string(forKey: "chartRange") ?? "") ?? .minutes3
        autoUpdateCheck = defaults.bool(forKey: "autoUpdateCheck")
        alertRunaway = defaults.bool(forKey: "alertRunaway")
        alertMemory = defaults.bool(forKey: "alertMemory")
        alertCharger = defaults.bool(forKey: "alertCharger")
        alertBatteryHot = defaults.bool(forKey: "alertBatteryHot")
        alertThermal = defaults.bool(forKey: "alertThermal")
        electricityPrice = defaults.double(forKey: "electricityPrice")
        currency = defaults.string(forKey: "currency") ?? "€"   // Bulgaria uses the euro since 1 Jan 2026
        notifyOnClean = defaults.bool(forKey: "notifyOnClean")
        autoCleanMinutes = defaults.integer(forKey: "autoCleanMinutes")
        autoCleanAbove = defaults.integer(forKey: "autoCleanAbove")
    }
}

/// Text in the current language: tr("Изход", "Quit").
func tr(_ bg: String, _ en: String) -> String {
    Settings.shared.language == .bg ? bg : en
}
