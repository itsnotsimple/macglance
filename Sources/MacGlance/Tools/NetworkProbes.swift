import Foundation
import Network

/// Checks that reach out to the internet, only while the Network page is open.
enum NetworkProbes {
    /// Round-trip time to Cloudflare's 1.1.1.1, in ms: how long a TCP connection takes to open
    /// (one round trip). A real ICMP ping would need admin rights; this doesn't.
    static func latency(completion: @escaping (Double?) -> Void) {
        let queue = DispatchQueue(label: "macglance.latency")
        let connection = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        let start = DispatchTime.now()
        var done = false
        func finish(_ result: Double?) {   // always on `queue`
            guard !done else { return }
            done = true
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            case .failed, .waiting: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }   // offline or very slow
    }

    /// The Mac's address on the internet and its country, from Cloudflare's trace page.
    static func publicAddress(completion: @escaping (_ ip: String?, _ country: String?) -> Void) {
        let url = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, _, _ in
            let fields = Dictionary(
                (String(data: data ?? Data(), encoding: .utf8) ?? "")
                    .split(separator: "\n")
                    .compactMap { line -> (String, String)? in
                        let parts = line.split(separator: "=", maxSplits: 1)
                        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
                    },
                uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async { completion(fields["ip"], fields["loc"]) }
        }.resume()
    }
}
