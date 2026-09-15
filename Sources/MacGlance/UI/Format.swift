func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

/// "0.04 W" below one watt (idle cores would all read 0.0), "4.1 W" above.
func watts(_ value: Double) -> String { String(format: value < 1 ? "%.2f W" : "%.1f W", value) }

/// "820 MB" below a gigabyte, "2.7 GB" above.
func memoryText(_ bytes: UInt64) -> String {
    bytes < 1 << 30 ? String(format: "%.0f MB", Double(bytes) / 1_048_576) : String(format: "%.1f GB", gb(bytes))
}

/// Disk sizes the way Finder shows them (1 GB = 1000 MB): "827 GB".
func diskText(_ bytes: UInt64) -> String {
    bytes >= 1_000_000_000_000 ? String(format: "%.2f TB", Double(bytes) / 1e12) : String(format: "%.0f GB", Double(bytes) / 1e9)
}

/// "0 KB/s", "850 KB/s", "9.5 MB/s".
func speedText(_ bytesPerSecond: Double) -> String {
    bytesPerSecond < 1e6 ? String(format: "%.0f KB/s", bytesPerSecond / 1e3) : String(format: "%.1f MB/s", bytesPerSecond / 1e6)
}

/// Short forms for the menu bar, never wider than their "widest" sample ("88.8M", "88.8 W", "888G").
func speedShort(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond < 1e6 { return String(format: "%.0fK", bytesPerSecond / 1e3) }
    if bytesPerSecond < 1e8 { return String(format: "%.1fM", bytesPerSecond / 1e6) }
    return String(format: "%.0fM", bytesPerSecond / 1e6)
}

/// Watts without the unit (the block's label says W): "4.1", "140".
func wattsShort(_ value: Double) -> String {
    value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
}

func diskShort(_ bytes: UInt64) -> String {
    bytes >= 1_000_000_000_000 ? String(format: "%.1fT", Double(bytes) / 1e12) : String(format: "%.0fG", Double(bytes) / 1e9)
}

/// "52°" (Celsius).
func degrees(_ value: Double) -> String { String(format: "%.0f°", value) }

/// "0.04 Wh", "3.2 Wh", "142 Wh", "1.23 kWh": enough digits that a few minutes of one app don't read 0.
func energyText(_ wattHours: Double) -> String {
    if wattHours >= 1000 { return String(format: "%.2f kWh", wattHours / 1000) }
    if wattHours >= 10 { return String(format: "%.0f Wh", wattHours) }
    if wattHours >= 1 { return String(format: "%.1f Wh", wattHours) }
    return String(format: "%.2f Wh", wattHours)
}

/// What that energy costs at the price from Settings, e.g. "0.02 €". Nil while no price is set.
func costText(_ wattHours: Double) -> String? {
    let settings = Settings.shared
    guard settings.electricityPrice > 0 else { return nil }
    let cost = wattHours / 1000 * settings.electricityPrice
    if cost > 0, cost < 0.001 { return "<0.001 " + settings.currency }
    return String(format: cost >= 1 ? "%.2f %@" : "%.3f %@", cost, settings.currency)
}

/// Data amounts the way Finder counts them (1 GB = 1000 MB): "740 MB", "45.2 GB", "10.84 TB".
func bytesText(_ bytes: Double) -> String {
    if bytes >= 1e12 { return String(format: "%.2f TB", bytes / 1e12) }
    if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
    if bytes >= 1e7 { return String(format: "%.0f MB", bytes / 1e6) }
    return String(format: "%.1f MB", bytes / 1e6)
}
