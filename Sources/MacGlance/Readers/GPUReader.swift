import Foundation
import IOKit

struct GPUStats {
    let load: Int              // 0...100, the whole GPU ("Device Utilization %")
    let renderer: Int          // 0...100, the stage that colors pixels
    let tiler: Int             // 0...100, the stage that sorts geometry into screen tiles
    let memoryInUse: UInt64?   // bytes of shared RAM the GPU holds right now
}

/// GPU numbers exactly as the graphics driver reports them in the IO registry.
final class GPUReader {
    /// "Apple M5" and the number of GPU cores, read once. Nil if the driver doesn't say.
    static let info: (model: String, cores: Int)? = {
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accelerator != 0 else { return nil }
        defer { IOObjectRelease(accelerator) }
        let model = IORegistryEntryCreateCFProperty(accelerator, "model" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        let cores = IORegistryEntryCreateCFProperty(accelerator, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        guard let model, let cores else { return nil }
        return (model, cores)
    }()

    private var accelerator: io_registry_entry_t = 0   // looked up once, then reused

    /// Nil if no GPU driver answered.
    func read() -> GPUStats? {
        if accelerator == 0 {
            accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            if accelerator == 0 { return nil }
        }
        guard let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary,
              let load = stats["Device Utilization %"] as? Int
        else {
            IOObjectRelease(accelerator)   // driver may have restarted, look it up again next time
            accelerator = 0
            return nil
        }
        return GPUStats(load: load,
                        renderer: stats["Renderer Utilization %"] as? Int ?? 0,
                        tiler: stats["Tiler Utilization %"] as? Int ?? 0,
                        memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }
}
