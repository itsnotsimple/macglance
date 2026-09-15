import CSensors

struct ThermalStatus {
    let pressure: Int?                  // 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping
    let frequencies: CPUFrequencies?    // average speed while working, per cluster

    /// What the pressure means, in words, and whether it's worth a warning.
    var summary: (text: String, warning: Bool) {
        switch pressure ?? 0 {
        case 0: (tr("Няма забавяне: чипът може да работи на пълна скорост", "No slowdown: the chip can run at full speed"), false)
        case 1: (tr("Леко ограничаване заради топлината", "Slightly held back because of heat"), false)
        case 2: (tr("Забавяне заради топлината: чипът работи по-бавно, за да се охлади", "Slowed down by heat: the chip runs slower to cool off"), true)
        default: (tr("Силно забавяне: Макът прегрява", "Heavily slowed down: the Mac is overheating"), true)
        }
    }
}

/// How hard macOS is holding the chip back because of heat, and the real core speeds.
/// The speeds are measured between two calls; only one reader should ask for them
/// (the Temperatures page), since the C side keeps a single baseline.
final class ThermalReader {
    func read(withFrequencies: Bool = true) -> ThermalStatus {
        let level = thermal_pressure_level()
        var frequencies = CPUFrequencies()
        let measured = withFrequencies && cpu_frequencies(&frequencies)
        return ThermalStatus(pressure: level >= 0 ? Int(level) : nil, frequencies: measured ? frequencies : nil)
    }
}
