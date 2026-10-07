import Foundation

/// What MacGlance hands to its widgets: the latest numbers plus the last hour, one value a minute.
/// The app writes it as JSON; the widget extension (sandboxed) may only read this one folder.
public struct WidgetSnapshot: Codable {
    public var time: Date
    public var language: String                  // "bg" or "en", as set in MacGlance

    public var cpu: Double?                      // %
    public var pCores: Double?
    public var eCores: Double?
    public var gpu: Double?                      // %
    public var gpuWatts: Double?
    public var gpuMemory: Double?                // bytes
    public var ramUsed: Double?                  // bytes
    public var ramTotal: Double?
    public var ramPressure: Int?                 // 1 normal, 2 warning, 4 critical
    public var swap: Double?
    public var watts: Double?                    // whole system
    public var cpuWatts: Double?
    public var down: Double?                     // bytes/s
    public var up: Double?
    public var todayTraffic: Double?             // bytes
    public var cpuTemperature: Double?           // °C, hottest spot
    public var gpuTemperature: Double?
    public var ssdTemperature: Double?
    public var battery: Int?                     // %
    public var charging: Bool?
    public var pluggedIn: Bool?
    public var minutesLeft: Int?
    public var cycles: Int?
    public var history: [String: [Double]]       // "cpu", "gpu", "power", "networkDown", "cpuTemperature"

    public init(time: Date, language: String) {
        self.time = time
        self.language = language
        self.history = [:]
    }
}

public enum WidgetShared {
    /// The real home folder. Inside the sandbox, the usual APIs point at the widget's container instead.
    public static var realHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var snapshotURL: URL {
        realHome.appendingPathComponent("Library/Application Support/MacGlance/widgets.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(snapshot) { try? data.write(to: snapshotURL, options: .atomic) }
    }
}
