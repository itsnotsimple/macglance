import CSensors
import Foundation

/// One look at every process once a minute, shared by everything that counts per app: SSD writes
/// (DiskWriters) and who used the CPU, energy and GPU (AppHistory). The reading happens in the
/// background (~5 ms: every process, the GPU's clients, the SSD's counter), the counting on the main thread.
final class MinuteSampler {
    static let shared = MinuteSampler()

    struct Reading {
        let pid: pid_t
        let key: String       // "pid-start": stays unique when macOS reuses a pid
        let written: Double   // bytes written to disk so far
        let cpu: UInt64       // CPU time so far, mach units
        let energy: UInt64    // CPU energy so far, nJ
    }

    struct Snapshot {
        let time: Date
        let processes: [Reading]        // the ones readable without admin rights
        let gpu: [pid_t: UInt64]        // GPU time so far per process, ns (every process, system ones too)
        let gpuNames: [pid_t: String]
        let ssdWritten: Double?         // the SSD's lifetime counter; nil if another app was reading it that moment
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "macglance.minute", qos: .utility)

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 10   // lets macOS run it together with other wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        queue.async {
            let time = Date()
            let processes = Processes.all().compactMap { pid -> Reading? in
                guard let usage = Processes.usage(pid) else { return nil }   // root processes need admin rights
                return Reading(pid: pid, key: "\(pid)-\(usage.ri_proc_start_abstime)", written: Double(usage.ri_diskio_byteswritten),
                               cpu: usage.ri_user_time + usage.ri_system_time, energy: usage.ri_energy_nj)
            }
            let (gpu, gpuNames) = ProcessGPUReader.gpuTimeByProcess()
            var smart = SSDSmart()
            let ssd = ssd_smart(&smart) ? smart.bytesWritten : nil
            let snapshot = Snapshot(time: time, processes: processes, gpu: gpu, gpuNames: gpuNames, ssdWritten: ssd)
            DispatchQueue.main.async {
                DiskWriters.shared.take(snapshot)
                AppHistory.shared.take(snapshot)
            }
        }
    }
}
