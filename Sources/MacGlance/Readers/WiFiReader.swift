import CoreWLAN
import Foundation

struct WiFiInfo {
    let rssi: Int            // signal, dBm: closer to 0 is stronger
    let noise: Int           // dBm
    let rate: Double         // link speed, Mbps
    let channel: Int?
    let band: String?        // "2.4 GHz", "5 GHz", "6 GHz"
    let width: Int?          // MHz
    let standard: String?    // "Wi-Fi 6 (802.11ax)"

    /// How good the signal is, in words.
    var quality: String {
        switch rssi {
        case (-50)...: tr("отличен", "excellent")
        case (-60)...: tr("добър", "good")
        case (-70)...: tr("среден", "fair")
        default: tr("слаб", "weak")
        }
    }
}

/// Wi-Fi details from CoreWLAN. The network's name (SSID) would need location permission,
/// so it's left out; everything here works without asking.
enum WiFiReader {
    static func read() -> WiFiInfo? {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), wifi.rssiValue() != 0 else { return nil }
        let channel = wifi.wlanChannel()
        let band: String? = switch channel?.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
        let width: Int? = switch channel?.channelWidth {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
        let standard: String? = switch wifi.activePHYMode() {
        case .mode11n: "Wi-Fi 4 (802.11n)"
        case .mode11ac: "Wi-Fi 5 (802.11ac)"
        case .mode11ax: "Wi-Fi 6 (802.11ax)"
        case .modeNone: nil
        default: "Wi-Fi 7 (802.11be)"   // newer than the SDK's names; a/b/g are long gone on Apple Silicon Macs
        }
        return WiFiInfo(rssi: wifi.rssiValue(), noise: wifi.noiseMeasurement(), rate: wifi.transmitRate(),
                        channel: channel?.channelNumber, band: band, width: width, standard: standard)
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet ("en" interfaces).
    static func localIP() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }

    /// 172.20.10.x is the network an iPhone's Personal Hotspot hands out: the data is mobile.
    static func isPersonalHotspot(_ ip: String?) -> Bool {
        ip?.hasPrefix("172.20.10.") == true
    }
}
