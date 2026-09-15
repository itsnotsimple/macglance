import Darwin

/// Helpers shared by the readers that look at every process (RAM per app, CPU per app).
enum Processes {
    /// Every process id on the Mac.
    static func all() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, found)).filter { $0 > 0 }
    }

    /// Memory, CPU time and energy of a process (v6 adds ri_energy_nj). Nil for system processes, which need root.
    static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    /// The process macOS holds responsible for this one, e.g. Safari for its web page processes.
    static func owner(of pid: pid_t) -> pid_t {
        let owner = responsiblePID(pid)
        return owner > 0 ? owner : pid
    }

    /// Short process name, e.g. "photoanalysisd".
    static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }
}

/// Private but long-standing; Activity Monitor groups processes the same way.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t
