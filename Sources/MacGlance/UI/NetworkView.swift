import SwiftUI

/// Live data for the Network page. Refreshes only while the page is on screen;
/// the latency every 10 s and the public address once per opening.
final class NetworkModel: ObservableObject {
    @Published private(set) var usage: NetworkUsage?
    @Published private(set) var wifi: WiFiInfo?
    @Published private(set) var localIP: String?
    @Published private(set) var latency: Double?     // ms
    @Published private(set) var publicIP: String?
    @Published private(set) var country: String?
    @Published var downHover: Int?
    @Published var upHover: Int?
    private let reader = NetworkReader()
    private var timer: Timer?
    private var lastLatency = Date.distantPast

    func start() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }   // speeds need two samples
        NetworkProbes.publicAddress { [weak self] ip, country in
            self?.publicIP = ip
            self?.country = country
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Settings.shared.interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        usage = reader.read() ?? usage
        wifi = WiFiReader.read()
        localIP = WiFiReader.localIP()
        if Date().timeIntervalSince(lastLatency) >= 10 {
            lastLatency = Date()
            NetworkProbes.latency { [weak self] in self?.latency = $0 }
        }
    }
}

struct NetworkView: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section { summary }

            if WiFiReader.isPersonalHotspot(model.localIP) {
                Section {
                    Label {
                        Text(tr("Свързан си към iPhone Personal Hotspot: данните са мобилни. Днес: ",
                                "You're on an iPhone Personal Hotspot: this is mobile data. Today: ")
                             + bytesText(DailyTraffic.shared.down + DailyTraffic.shared.up))
                    } icon: {
                        Image(systemName: "personalhotspot").foregroundStyle(.blue)
                    }
                }
            }

            HistoryPanel(tr("Сваляне", "Download"), metric: .networkDown, maxValue: Self.scaleTop,
                         format: speedShortUnit, hoverIndex: $model.downHover)
            HistoryPanel(tr("Качване", "Upload"), metric: .networkUp, maxValue: Self.scaleTop,
                         format: speedShortUnit, showsPicker: false, hoverIndex: $model.upHover)

            if let wifi = model.wifi {
                Section("Wi-Fi") {
                    row(tr("Сигнал", "Signal"), "\(wifi.rssi) dBm · \(wifi.quality)")
                        .help(tr("По-близо до 0 е по-силно: −50 и нагоре е отличен, под −70 е слаб.",
                                 "Closer to 0 is stronger: −50 and up is excellent, below −70 is weak."))
                    row(tr("Шум", "Noise"), "\(wifi.noise) dBm")
                    row(tr("Скорост на връзката", "Link speed"), String(format: "%.0f Mbps", wifi.rate))
                        .help(tr("Колко бързо говорят Макът и рутерът, не колко бърз е интернетът.",
                                 "How fast the Mac and the router talk, not how fast the internet is."))
                    if let channel = wifi.channel {
                        row(tr("Канал", "Channel"), ["\(channel)", wifi.band, wifi.width.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let standard = wifi.standard {
                        row(tr("Стандарт", "Standard"), standard)
                    }
                }
            }

            Section {
                row(tr("Локален IP", "Local IP"), model.localIP ?? "–")
                row(tr("Публичен IP", "Public IP"), model.publicIP ?? "…")
                if let country = model.country {
                    row(tr("Държава", "Country"), country)
                }
            } header: {
                Text(tr("Адреси", "Addresses"))
            } footer: {
                Text(tr("Публичният IP и закъснението се проверяват при Cloudflare (1.1.1.1), само докато тази страница е отворена.",
                        "The public IP and the latency are checked with Cloudflare (1.1.1.1), only while this page is open."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(tr("Днес", "Today")) {
                row(tr("Свалени", "Downloaded"), bytesText(DailyTraffic.shared.down))
                row(tr("Качени", "Uploaded"), bytesText(DailyTraffic.shared.up))
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// Steps of 100 KB/s, 1, 5, 10, 25, 50, 100 MB/s… so the chart rarely rescales.
    private static func scaleTop(_ samples: [Sample]) -> Double {
        let peak = samples.map(\.value).max() ?? 0
        return [1e5, 1e6, 5e6, 1e7, 2.5e7, 5e7, 1e8, 2.5e8, 5e8, 1e9].first { $0 >= peak * 1.1 } ?? 2e9
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.usage.map { speedText($0.downPerSecond) } ?? "–")
                    .font(.system(size: 34, weight: .semibold))
                Text(tr("Сваляне", "Download")).foregroundStyle(.secondary)
            }
            Spacer()
            tile(tr("Качване", "Upload"), model.usage.map { speedText($0.upPerSecond) } ?? "–")
            tile(tr("Закъснение", "Latency"), model.latency.map { String(format: "%.0f ms", $0) } ?? "…")
                .help(tr("Време за отиване и връщане до Cloudflare (1.1.1.1). Под 30 ms е отлично, над 100 ms се усеща в игри и разговори.",
                         "Round trip to Cloudflare (1.1.1.1). Under 30 ms is excellent; over 100 ms is noticeable in games and calls."))
            tile(tr("Днес общо", "Today in total"), bytesText(DailyTraffic.shared.down + DailyTraffic.shared.up))
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Axis and hover labels for speeds: "500 KB/s", "12 MB/s".
private func speedShortUnit(_ bytesPerSecond: Double) -> String {
    bytesPerSecond < 1e6 ? String(format: "%.0f KB/s", bytesPerSecond / 1e3) : String(format: "%.0f MB/s", bytesPerSecond / 1e6)
}
