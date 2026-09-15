import CSensors
import Foundation

struct Temperatures {
    let pCores: [Double]   // °C, one value per sensor
    let eCores: [Double]
    let gpu: [Double]
    let ssd: Double?
    let battery: Double?

    /// The hottest spot is what matters: that's what makes macOS slow the chip down.
    var cpu: Double? { (pCores + eCores).max() }
    var gpuMax: Double? { gpu.max() }
}

/// Temperatures from the SMC (CPU, GPU, battery) and one HID sensor (SSD).
final class TemperatureReader {
    /// SMC key names differ between chips, so the Mac's own keys are listed once and sorted
    /// by prefix. Matched by heating one part at a time on an M5:
    /// Tp = P-cores, Te = E-cores, Tg = GPU, TB = battery.
    /// (TH looked like the SSD but barely moved during 9 GB of writes; the HID "NAND" sensor did.)
    private struct Keys {
        var pCores: [String] = []
        var eCores: [String] = []
        var gpu: [String] = []
        var battery: [String] = []
    }

    private let smcReady = smc_open()
    private lazy var keys = discoverKeys()

    /// Each SMC read takes ~0.1 ms (the SMC is a separate chip), so the menu bar asks for
    /// the 18 CPU sensors only; the full set (~45) is read while the Temperatures page is open.
    func read(cpuOnly: Bool = false) -> Temperatures? {
        guard smcReady else { return nil }
        let pCores = keys.pCores.compactMap(knownValue)
        let eCores = keys.eCores.compactMap(knownValue)
        if cpuOnly { return Temperatures(pCores: pCores, eCores: eCores, gpu: [], ssd: nil, battery: nil) }
        let ssd = hid_temperature("NAND")
        return Temperatures(pCores: pCores,
                            eCores: eCores,
                            gpu: keys.gpu.compactMap(knownValue),
                            ssd: ssd.isNaN ? nil : ssd,
                            battery: keys.battery.compactMap(knownValue).max())
    }

    /// Just the GPU sensors (hottest one), for the GPU page.
    func gpuTemperature() -> Double? {
        guard smcReady else { return nil }
        return keys.gpu.compactMap(knownValue).max()
    }

    /// Just the battery sensors, for the Battery page.
    func batteryTemperature() -> Double? {
        guard smcReady else { return nil }
        return keys.battery.compactMap(knownValue).max()
    }

    /// Checks the key's type first; used once per key while discovering.
    private func value(_ key: String) -> Double? {
        var reading: Float = 0
        guard smc_read_float(key, &reading), (1...150).contains(reading) else { return nil }   // skip dead sensors
        return Double(reading)
    }

    /// For keys already checked: one call instead of two.
    private func knownValue(_ key: String) -> Double? {
        var reading: Float = 0
        guard smc_read_known_float(key, &reading), (1...150).contains(reading) else { return nil }
        return Double(reading)
    }

    /// Walks all ~2400 key names once; only the ~50 with a wanted prefix get read.
    private func discoverKeys() -> Keys {
        var keys = Keys()
        var name = [CChar](repeating: 0, count: 5)
        for index in 0..<smc_key_count() {
            guard smc_key_at_index(Int32(index), &name), name[0] == CChar(UInt8(ascii: "T")) else { continue }
            let key = String(cString: name)
            let prefix = key.prefix(2)
            guard ["Tp", "Te", "Tg", "TB"].contains(prefix),
                  value(key) != nil else { continue }   // not a float, or no sensible reading
            switch prefix {
            case "Tp": keys.pCores.append(key)
            case "Te": keys.eCores.append(key)
            case "Tg": keys.gpu.append(key)
            case "TB" where key.hasSuffix("T"): keys.battery.append(key)   // TB0T, TB1T, TB2T
            default: break
            }
        }
        return keys
    }
}
