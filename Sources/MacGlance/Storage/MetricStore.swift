import Foundation

enum Metric: String, CaseIterable, Codable {
    case cpu              // load, %
    case gpu              // load, %
    case power            // whole system, W
    case cpuTemperature   // hottest CPU spot, °C
    case networkDown      // bytes/s
    case networkUp        // bytes/s
}

enum TimeRange: String, CaseIterable, Identifiable {
    case minutes3, hour1, hours2, day1, days7
    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .minutes3: 180
        case .hour1: 3600
        case .hours2: 7200
        case .day1: 86400
        case .days7: 7 * 86400
        }
    }

    var label: String {
        switch self {
        case .minutes3: tr("3 мин", "3 min")
        case .hour1: tr("1 ч", "1 h")
        case .hours2: tr("2 ч", "2 h")
        case .day1: tr("24 ч", "24 h")
        case .days7: tr("7 дни", "7 days")
        }
    }
}

struct Sample: Codable {
    let time: TimeInterval   // seconds since 1970
    let value: Double
}

/// History for the charts, from 3 minutes up to 7 days, kept on disk so it survives restarts.
/// The last 2 hours are kept in full detail (every tick); older data as one average per minute.
/// 7 days × 4 metrics ≈ 40,000 minute values, about half a megabyte on disk.
final class MetricStore {
    static let shared = MetricStore()
    private static let detailedSpan: TimeInterval = 2 * 3600
    private static let keptSpan: TimeInterval = 7 * 86400

    private var detailed: [Metric: [Sample]] = [:]                            // every tick, last 2 hours
    private var minutes: [Metric: [Sample]] = [:]                             // one average per minute, last 7 days
    private var openMinute: [Metric: (start: TimeInterval, sum: Double, count: Int)] = [:]
    private var lastSave = Date()
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.plist")
    }()

    private init() {
        load()
    }

    func record(_ metric: Metric, _ value: Double, at date: Date = Date()) {
        let time = date.timeIntervalSince1970
        detailed[metric, default: []].append(Sample(time: time, value: value))
        dropOlder(than: time - Self.detailedSpan, in: &detailed[metric, default: []])

        // Average per minute: when a new minute starts, the finished one is stored.
        let minuteStart = (time / 60).rounded(.down) * 60
        if var open = openMinute[metric], open.start == minuteStart {
            open.sum += value
            open.count += 1
            openMinute[metric] = open
        } else {
            if let open = openMinute[metric] {
                minutes[metric, default: []].append(Sample(time: open.start + 30, value: open.sum / Double(open.count)))
                dropOlder(than: time - Self.keptSpan, in: &minutes[metric, default: []])
            }
            openMinute[metric] = (minuteStart, value, 1)
        }

        if date.timeIntervalSince(lastSave) > 600 { save() }   // every 10 minutes, and on quit
    }

    /// The samples in `range`, at most `maxPoints` of them: long ranges are averaged into
    /// buckets so a 7-day chart stays as light to draw as a 3-minute one.
    func samples(_ metric: Metric, in range: TimeRange, maxPoints: Int = 400) -> [Sample] {
        let now = Date().timeIntervalSince1970
        let from = now - range.seconds
        let recent = detailed[metric] ?? []
        let detailStart = recent.first?.time ?? now
        // Minute averages fill the part the detailed list doesn't reach (e.g. before a restart).
        let older = (minutes[metric] ?? []).filter { $0.time >= from && $0.time < detailStart }
        return downsample(older + recent.filter { $0.time >= from }, from: from, to: now, maxPoints: maxPoints)
    }

    func save() {
        lastSave = Date()
        let stored = Dictionary(uniqueKeysWithValues: minutes.map { ($0.key.rawValue, $0.value) })
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(stored) { try? data.write(to: file, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? PropertyListDecoder().decode([String: [Sample]].self, from: data) else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.keptSpan
        for (key, samples) in stored {
            if let metric = Metric(rawValue: key) { minutes[metric] = samples.filter { $0.time >= cutoff } }
        }
    }

    private func dropOlder(than cutoff: TimeInterval, in samples: inout [Sample]) {
        let stale = samples.prefix { $0.time < cutoff }.count
        if stale > 0 { samples.removeFirst(stale) }
    }

    private func downsample(_ samples: [Sample], from: TimeInterval, to: TimeInterval, maxPoints: Int) -> [Sample] {
        guard samples.count > maxPoints else { return samples }
        let bucketWidth = (to - from) / Double(maxPoints)
        var result: [Sample] = []
        var bucket = -1
        var timeSum = 0.0, valueSum = 0.0, count = 0.0
        func flush() {
            if count > 0 { result.append(Sample(time: timeSum / count, value: valueSum / count)) }
        }
        for sample in samples {
            let index = Int((sample.time - from) / bucketWidth)
            if index != bucket {
                flush()
                bucket = index
                timeSum = 0; valueSum = 0; count = 0
            }
            timeSum += sample.time
            valueSum += sample.value
            count += 1
        }
        flush()
        return result
    }
}
