import Foundation

/// "Free RAM", like Mem Reduct on Windows.
/// It locks chunks of RAM for itself (locked memory can't be compressed or swapped),
/// so macOS has to make room: it drops file cache and compresses the memory of apps
/// you are not using. Then it gives everything back. The Used number drops, but those
/// apps need a moment to decompress when you go back to them.
/// It stops the moment macOS reports memory pressure, so apps never get closed.
final class RAMCleaner: ObservableObject {
    static let shared = RAMCleaner()

    @Published private(set) var isRunning = false
    @Published private(set) var lastFreed: Int64?   // bytes, from the last run

    private let chunkSize = 256 << 20   // claim 256 MB at a time
    private let timeLimit: TimeInterval = 20
    private let settings = Settings.shared
    private var autoTimer: Timer?
    private var autoMinutes = 0

    func run(automatic: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        DispatchQueue.global(qos: .utility).async {
            let reader = MemoryReader()
            let before = reader.read()
            self.squeeze(total: before?.total ?? 0)
            Thread.sleep(forTimeInterval: 1)   // let the counters settle
            let after = reader.read()
            DispatchQueue.main.async {
                if let before, let after {
                    let freed = Int64(before.used) - Int64(after.used)
                    self.lastFreed = freed
                    if self.settings.notifyOnClean { self.notify(freed: freed, after: after, automatic: automatic) }
                }
                self.isRunning = false
            }
        }
    }

    // MARK: - Automatic

    /// Starts, restarts or stops the automatic timer to match the settings. Safe to call often.
    func applySchedule() {
        guard settings.autoCleanMinutes != autoMinutes else { return }   // unchanged: keep the countdown
        autoMinutes = settings.autoCleanMinutes
        autoTimer?.invalidate()
        autoTimer = nil
        guard autoMinutes > 0 else { return }

        let interval = TimeInterval(autoMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.autoTick() }
        timer.tolerance = 60   // a minute either way is fine, saves wakeups
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    private func autoTick() {
        let threshold = Double(settings.autoCleanAbove)
        guard let usage = MemoryReader().read(), usage.usedPercent >= threshold else { return }
        run(automatic: true)
    }

    // MARK: - Work

    private func notify(freed: Int64, after: MemoryUsage, automatic: Bool) {
        let title = automatic ? tr("Автоматично освобождаване на RAM", "RAM freed automatically")
                              : tr("RAM е освободена", "RAM freed")
        let result = freed > 0 ? tr("Освободени ", "Freed ") + memoryText(UInt64(freed))
                               : tr("Нямаше какво да се освободи", "Nothing to free")
        let now = String(format: tr("Сега: %.1f от %.0f GB", "Now: %.1f of %.0f GB"), gb(after.used), gb(after.total))
        Notifier.shared.post(title: title, body: "\(result) · \(now)")
    }

    private func squeeze(total: UInt64) {
        var chunks: [UnsafeMutableRawPointer] = []
        let maxChunks = Int(Double(total) * 0.9) / chunkSize   // never more than 90% of RAM
        let deadline = Date().addingTimeInterval(timeLimit)

        while chunks.count < maxChunks, Date() < deadline, MemoryReader.pressure() == .normal {
            guard let chunk = mmap(nil, chunkSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  chunk != UnsafeMutableRawPointer(bitPattern: -1) else { break }
            guard mlock(chunk, chunkSize) == 0 else {   // over the system's lock limit: enough
                munmap(chunk, chunkSize)
                break
            }
            chunks.append(chunk)
        }

        for chunk in chunks {
            munlock(chunk, chunkSize)
            munmap(chunk, chunkSize)
        }
    }
}
