import Darwin
import Foundation

struct NetworkUsage {
    let downPerSecond: Double   // bytes/s
    let upPerSecond: Double
    let totalDown: UInt64       // bytes since boot, for the daily traffic count
    let totalUp: UInt64
}

/// Download and upload speed over the real network ports (Wi-Fi, Ethernet: the "en" interfaces).
/// VPN tunnels and AirDrop are left out, their traffic already goes through Wi-Fi or Ethernet.
final class NetworkReader {
    private var previous: (down: UInt64, up: UInt64, time: Date)?

    /// Nil on the first call, or when the last one was too long ago to be a fair baseline.
    func read() -> NetworkUsage? {
        guard let totals = totals() else { return nil }
        let now = Date()
        defer { previous = (totals.down, totals.up, now) }
        guard let previous else { return nil }
        let seconds = now.timeIntervalSince(previous.time)
        guard seconds > 0, seconds < 10, totals.down >= previous.down, totals.up >= previous.up else { return nil }
        return NetworkUsage(downPerSecond: Double(totals.down - previous.down) / seconds,
                            upPerSecond: Double(totals.up - previous.up) / seconds,
                            totalDown: totals.down, totalUp: totals.up)
    }

    /// Bytes since boot from the kernel's interface list. These counters are 64-bit;
    /// the ones from getifaddrs are 32-bit and wrap around every 4 GB.
    private func totals() -> (down: UInt64, up: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }

        let nameLengthField = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_nlen)!
        let nameField = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!
        var down: UInt64 = 0
        var up: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                // Messages are packed back to back, so the reads must not assume alignment.
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if header.ifm_msglen == 0 { break }   // malformed, don't loop forever
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }

                // The interface name ("en0") sits in the link address right after the message.
                let link = offset + MemoryLayout<if_msghdr2>.size
                let nameStart = link + nameField
                let nameLength = Int(raw[link + nameLengthField])
                guard nameLength >= 2, nameStart + nameLength <= offset + Int(header.ifm_msglen),
                      raw[nameStart] == UInt8(ascii: "e"), raw[nameStart + 1] == UInt8(ascii: "n") else { continue }

                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                down += info.ifm_data.ifi_ibytes
                up += info.ifm_data.ifi_obytes
            }
        }
        return (down, up)
    }
}
