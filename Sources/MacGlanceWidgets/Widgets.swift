import Shared
import SwiftUI
import WidgetKit

// MARK: - Data

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?   // nil: MacGlance hasn't written anything yet
}

/// Reads the snapshot MacGlance writes once a minute. macOS decides how often widgets
/// actually refresh (every few minutes); asking for 5 is a polite default.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WidgetShared.load() ?? Self.sample))   // the gallery preview
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: .now, snapshot: WidgetShared.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
    }

    /// Believable numbers for the widget gallery, before MacGlance has data.
    static let sample: WidgetSnapshot = {
        var s = WidgetSnapshot(time: .now, language: Locale.preferredLanguages.contains { $0.hasPrefix("bg") } ? "bg" : "en")
        s.cpu = 12; s.pCores = 18; s.eCores = 8; s.gpu = 4; s.gpuWatts = 0.3; s.gpuMemory = 4e8
        s.ramUsed = 1.1e10; s.ramTotal = 1.7e10; s.ramPressure = 1; s.swap = 6e8
        s.watts = 6.4; s.cpuWatts = 1.2; s.down = 2.4e6; s.up = 9.6e4; s.todayTraffic = 1.9e9
        s.cpuTemperature = 48; s.gpuTemperature = 41; s.ssdTemperature = 33
        s.battery = 80; s.charging = false; s.pluggedIn = true; s.cycles = 11
        let wave = (0..<60).map { 10 + 8 * sin(Double($0) / 6) }
        s.history = ["cpu": wave, "gpu": wave.map { $0 / 3 }, "power": wave.map { $0 / 2 },
                     "networkDown": wave.map { $0 * 1e5 }, "cpuTemperature": wave.map { 38 + $0 }]
        return s
    }()
}

// MARK: - Widgets

enum Kind: String, CaseIterable {
    case cpu, gpu, ram, power, network, temperature, battery
}

/// One widget per metric, small or medium. (WidgetKit wants each widget as its own type.)
func metricConfiguration(_ kind: Kind) -> some WidgetConfiguration {
    StaticConfiguration(kind: "macglance.\(kind.rawValue)", provider: Provider()) { entry in
        MetricView(kind: kind, entry: entry)
    }
    .configurationDisplayName(Text.localized(kind.title))
    .description(Text.localized(Words("Обновява се на няколко минути.", "Updates every few minutes.")))
    .supportedFamilies([.systemSmall, .systemMedium])
}

struct CPUWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.cpu) } }
struct GPUWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.gpu) } }
struct RAMWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.ram) } }
struct PowerWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.power) } }
struct NetworkWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.network) } }
struct TemperatureWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.temperature) } }
struct BatteryWidget: Widget { var body: some WidgetConfiguration { metricConfiguration(.battery) } }

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "macglance.overview", provider: Provider()) { entry in
            OverviewView(entry: entry)
        }
        .configurationDisplayName("MacGlance")
        .description(Text.localized(Words("CPU, GPU, RAM, ватове, мрежа и температура наведнъж.",
                                          "CPU, GPU, RAM, watts, network and temperature at once.")))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct MacGlanceWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        CPUWidget()
        GPUWidget()
        RAMWidget()
        PowerWidget()
        NetworkWidget()
        TemperatureWidget()
        BatteryWidget()
    }
}
