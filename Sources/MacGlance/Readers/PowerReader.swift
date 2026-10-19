import CSensors
import Foundation
import IOKit

struct PowerUsage {
    let system: Double     // the whole computer, watts
    let pCores: Double     // P-cores and their cache
    let eCores: Double
    let gpu: Double
    let adapter: Double    // drawn from the charger, ~0 on battery
    let battery: Double?   // + charging, − powering the Mac; nil on Macs without a battery

    var cpu: Double { pCores + eCores }

    /// Everything else: screen, RAM, SSD, Wi-Fi... Never below 0 if the sensors disagree slightly.
    var other: Double { max(0, system - cpu - gpu) }
}

/// Watts from the SMC and the battery controller.
final class PowerReader {
    /// SMC key names are undocumented. These were matched by load tests on an M5:
    /// load only the P-cores, only the E-cores, only the GPU, and see which sensor moves.
    private enum Key {
        static let system = "PSTR"
        static let adapter = "PDTR"
        static let pCores = "PP0b"
        static let pCoresCache = "PP7b"   // moves together with PP0b, most likely the P-cluster cache
        static let eCores = "PPbb"
        static let gpu = "PP1b"
    }

    private let smcReady = smc_open()
    private var battery: io_registry_entry_t = 0   // looked up once, then reused

    /// `detailed: false` reads only the whole system, the charger and the GPU (3 SMC calls instead of 6
    /// plus the battery): enough for the menu bar, the charts and the electricity log. CPU watts are 0 then.
    func read(detailed: Bool = true) -> PowerUsage? {
        guard smcReady, let system = smc(Key.system) else { return nil }
        return PowerUsage(system: system,
                          pCores: detailed ? (smc(Key.pCores) ?? 0) + (smc(Key.pCoresCache) ?? 0) : 0,
                          eCores: detailed ? smc(Key.eCores) ?? 0 : 0,
                          gpu: smc(Key.gpu) ?? 0,
                          adapter: smc(Key.adapter) ?? 0,
                          battery: detailed ? batteryWatts() : nil)
    }

    private var checkedKeys: Set<String> = []   // keys whose type was already confirmed as float

    /// The first read of a key also asks the SMC for its type; later reads skip that (half the calls).
    private func smc(_ key: String) -> Double? {
        var value: Float = 0
        if checkedKeys.contains(key) {
            return smc_read_known_float(key, &value) ? Double(value) : nil
        }
        guard smc_read_float(key, &value) else { return nil }
        checkedKeys.insert(key)
        return Double(value)
    }

    /// Voltage × current straight from the battery controller.
    private func batteryWatts() -> Double? {
        if battery == 0 {
            battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if battery == 0 { return nil }
        }
        guard let millivolts = batteryProperty("Voltage"),
              let milliamps = batteryProperty("InstantAmperage") else { return nil }
        return Double(millivolts) * Double(milliamps) / 1_000_000
    }

    private func batteryProperty(_ name: String) -> Int64? {
        // int64Value, because a negative current comes stored as a huge unsigned number
        (IORegistryEntryCreateCFProperty(battery, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.int64Value
    }
}
