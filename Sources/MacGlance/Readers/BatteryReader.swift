import Foundation
import IOKit

struct BatteryInfo {
    let percent: Int              // charge, 0...100
    let isCharging: Bool
    let isPluggedIn: Bool
    let isFull: Bool
    let minutesLeft: Int?         // to empty on battery, to full while charging; nil while macOS still estimates
    let cycles: Int
    let designCycles: Int?        // cycles the battery is rated for (1000 on current MacBooks)
    let designCapacity: Int       // mAh when new
    let fullCapacity: Int         // mAh it holds now when full
    let charge: Int               // mAh in it right now
    let voltage: Double           // V
    let watts: Double             // + charging, − powering the Mac
    let adapterWatts: Int?        // what the charger is rated for

    /// Capacity left compared to new, from the mAh numbers (the way coconutBattery counts it).
    var capacityPercent: Double { Double(fullCapacity) / Double(designCapacity) * 100 }
}

/// Everything the battery controller reports (no admin rights needed).
final class BatteryReader {
    private var battery: io_registry_entry_t = 0   // looked up once, then reused

    /// Nil on Macs without a battery.
    func read() -> BatteryInfo? {
        if battery == 0 {
            battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if battery == 0 { return nil }
        }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(battery, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              properties["BatteryInstalled"] as? Bool == true else { return nil }
        let details = properties["BatteryData"] as? [String: Any] ?? [:]
        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]

        func int(_ dictionary: [String: Any], _ key: String) -> Int? {
            (dictionary[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }   // negative amps come unsigned
        }

        let charging = properties["IsCharging"] as? Bool ?? false
        let pluggedIn = properties["ExternalConnected"] as? Bool ?? false
        let minutes = charging ? int(properties, "AvgTimeToFull") : (pluggedIn ? nil : int(properties, "AvgTimeToEmpty"))
        let millivolts = int(properties, "Voltage") ?? 0
        let milliamps = int(properties, "InstantAmperage") ?? 0

        return BatteryInfo(percent: int(properties, "CurrentCapacity") ?? 0,
                           isCharging: charging,
                           isPluggedIn: pluggedIn,
                           isFull: properties["FullyCharged"] as? Bool ?? false,
                           minutesLeft: minutes == 65535 ? nil : minutes,   // 65535 = "still estimating"
                           cycles: int(properties, "CycleCount") ?? 0,
                           designCycles: int(properties, "DesignCycleCount9C"),
                           designCapacity: int(details, "DesignCapacity") ?? 0,
                           fullCapacity: int(details, "NominalChargeCapacity") ?? 0,
                           charge: int(details, "RemainingCapacity") ?? 0,
                           voltage: Double(millivolts) / 1000,
                           watts: Double(millivolts) * Double(milliamps) / 1_000_000,
                           adapterWatts: pluggedIn ? int(adapter, "Watts") : nil)
    }

    /// Apple's own "Maximum Capacity" (e.g. "99%") and condition ("Good"), exactly as System Settings
    /// shows them. Apple computes them in a way the raw numbers don't reveal, so we ask
    /// system_profiler (~0.06 s). Run it off the main thread.
    static func appleHealth() -> (maximumCapacity: String, condition: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPPowerDataType"] as? [[String: Any]],
              let health = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first,
              let maximum = health["sppower_battery_health_maximum_capacity"] as? String,
              let condition = health["sppower_battery_health"] as? String else { return nil }
        return (maximum, condition)
    }
}
