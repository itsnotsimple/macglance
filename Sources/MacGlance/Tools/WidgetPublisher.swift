import Foundation
import Shared
import WidgetKit

/// Feeds the macOS widgets: a small JSON file with the latest numbers once a minute, and a nudge
/// to WidgetKit every 3 minutes (macOS decides the real refresh rate, usually every few minutes).
/// Nothing is written unless at least one MacGlance widget is placed somewhere.
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var inUse = false
    private var wroteOnce = false   // one write at launch, so the widget gallery shows real numbers
    private var lastUsageCheck = Date.distantPast
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private let memoryReader = MemoryReader()
    private let temperatures = TemperatureReader()
    private let batteryReader = BatteryReader()

    /// Called on every tick with what the menu bar already read.
    func tick(cpu: CPULoad?, gpu: GPUStats?, memory: MemoryUsage?, power: PowerUsage?, network: NetworkUsage?) {
        let now = Date()
        if now.timeIntervalSince(lastUsageCheck) >= 60 {
            lastUsageCheck = now
            WidgetCenter.shared.getCurrentConfigurations { result in
                let placed = (try? result.get())?.contains { $0.kind.hasPrefix("macglance.") } ?? false
                DispatchQueue.main.async {
                    if placed && !self.inUse { self.lastWrite = .distantPast }   // just placed: write right away
                    self.inUse = placed
                }
            }
        }
        // the launch write waits for the second tick, when CPU and network speeds have a baseline
        guard (inUse && now.timeIntervalSince(lastWrite) >= 60) || (!wroteOnce && cpu != nil && network != nil) else { return }
        wroteOnce = true
        lastWrite = now
        WidgetShared.save(snapshot(cpu: cpu, gpu: gpu, memory: memory ?? memoryReader.read(), power: power, network: network))
        if now.timeIntervalSince(lastReload) >= 180 {
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func snapshot(cpu: CPULoad?, gpu: GPUStats?, memory: MemoryUsage?, power: PowerUsage?, network: NetworkUsage?) -> WidgetSnapshot {
        var s = WidgetSnapshot(time: Date(), language: Settings.shared.language.rawValue)
        if let cpu {
            s.cpu = cpu.total
            let kinds = CPUReader.coreKinds
            if kinds.count == cpu.cores.count {
                func average(_ kind: CoreKind) -> Double? {
                    let values = zip(cpu.cores, kinds).filter { $0.1 == kind }.map(\.0)
                    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                }
                s.pCores = average(.performance)
                s.eCores = average(.efficiency)
            }
        }
        s.gpu = gpu.map { Double($0.load) }
        s.gpuWatts = power?.gpu
        s.gpuMemory = gpu?.memoryInUse.map(Double.init)
        s.ramUsed = memory.map { Double($0.used) }
        s.ramTotal = memory.map { Double($0.total) }
        s.ramPressure = memory.map { Int($0.pressure.rawValue) }
        s.swap = memory.map { Double($0.swap) }
        s.watts = power?.system
        s.cpuWatts = power?.cpu
        s.down = network?.downPerSecond
        s.up = network?.upPerSecond
        s.todayTraffic = DailyTraffic.shared.down + DailyTraffic.shared.up
        let temps = temperatures.read()   // ~4 ms, once a minute
        s.cpuTemperature = temps?.cpu
        s.gpuTemperature = temps?.gpuMax
        s.ssdTemperature = temps?.ssd
        if let battery = batteryReader.read() {
            s.battery = battery.percent
            s.charging = battery.isCharging
            s.pluggedIn = battery.isPluggedIn
            s.minutesLeft = battery.minutesLeft
            s.cycles = battery.cycles
        }
        // the last hour, one value a minute, for the charts
        for (key, metric) in [("cpu", Metric.cpu), ("gpu", .gpu), ("power", .power), ("networkDown", .networkDown), ("cpuTemperature", .cpuTemperature)] {
            s.history[key] = MetricStore.shared.samples(metric, in: .hour1, maxPoints: 60).map(\.value)
        }
        return s
    }
}
