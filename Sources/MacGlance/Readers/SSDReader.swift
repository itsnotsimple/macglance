import CSensors
import Foundation

struct SSDHealth {
    let wearPercent: Int          // 0 = new, 100 = rated life used up
    let spare: Int                // % of spare blocks left
    let spareThreshold: Int
    let criticalWarning: Int      // 0 = all good
    let temperature: Int          // °C
    let written: Double           // bytes, over the drive's life
    let read: Double
    let powerOnHours: Int
    let powerCycles: Int
    let unsafeShutdowns: Int
    let mediaErrors: Int
    let writtenToday: Double      // bytes since the first reading today

    var isHealthy: Bool { criticalWarning == 0 && spare >= spareThreshold && wearPercent < 90 && mediaErrors == 0 }
}

/// The internal SSD's own health log (NVMe SMART).
final class SSDReader {
    func read() -> SSDHealth? {
        var smart = SSDSmart()
        guard ssd_smart(&smart) else { return nil }

        // "Written today": the lifetime counter at the first reading of each day is the starting point.
        // The menu bar reads it every 30 minutes, so the day starts close to midnight (or at wake-up).
        let defaults = UserDefaults.standard
        let today = EnergyLedger.key(Date())
        if defaults.string(forKey: "ssdDay") != today {
            defaults.set(today, forKey: "ssdDay")
            defaults.set(smart.bytesWritten, forKey: "ssdWrittenAtDayStart")
        }
        let dayStart = defaults.double(forKey: "ssdWrittenAtDayStart")

        return SSDHealth(wearPercent: Int(smart.percentUsed),
                         spare: Int(smart.availableSpare),
                         spareThreshold: Int(smart.spareThreshold),
                         criticalWarning: Int(smart.criticalWarning),
                         temperature: Int(smart.temperature),
                         written: smart.bytesWritten,
                         read: smart.bytesRead,
                         powerOnHours: Int(smart.powerOnHours),
                         powerCycles: Int(smart.powerCycles),
                         unsafeShutdowns: Int(smart.unsafeShutdowns),
                         mediaErrors: Int(smart.mediaErrors),
                         writtenToday: max(0, smart.bytesWritten - dayStart))
    }
}
