import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

/// Raw byte counters for one network interface.
struct Counters {
    var rx: UInt64
    var tx: UInt64
}

/// Reads 64-bit interface counters straight from the kernel routing table
/// (NET_RT_IFLIST2). Unlike getifaddrs(), these counters don't wrap at 4 GB.
enum NetStats {
    // From <net/route.h>; defined locally so we don't depend on header import details.
    private static let netRtIflist2: Int32 = 6     // NET_RT_IFLIST2
    private static let rtmIfinfo2: Int32 = 0x12    // RTM_IFINFO2

    /// Virtual / loopback interfaces we skip so traffic isn't double counted
    /// (e.g. a VPN tunnel carries the same bytes as the physical en0).
    private static let excludedPrefixes = [
        "lo", "utun", "awdl", "llw", "bridge", "gif", "stf",
        "anpi", "ap", "ipsec", "vmenet", "XHC", "pktap", "ppp"
    ]

    static func isExcluded(_ name: String) -> Bool {
        excludedPrefixes.contains { name.hasPrefix($0) }
    }

    static func read() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRtIflist2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        let total = length
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= total {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                if messageLength <= 0 { break }

                if Int32(header.ifm_type) == rtmIfinfo2,
                   offset + MemoryLayout<if_msghdr2>.size <= total {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        let isUp = (info.ifm_flags & IFF_UP) != 0
                        if isUp && !isExcluded(name) {
                            result[name] = Counters(rx: info.ifm_data.ifi_ibytes,
                                                    tx: info.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}

/// Figures out which interface macOS is currently routing through and what kind it is.
enum NetInfo {
    enum Kind: String {
        case wifi = "Wi-Fi", ethernet = "Ethernet", vpn = "VPN", cellular = "Cellular", other = "Network", offline = "Offline"

        var symbol: String {
            switch self {
            case .wifi: return "wifi"
            case .ethernet: return "cable.connector"
            case .vpn: return "lock.shield"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other: return "network"
            case .offline: return "wifi.slash"
            }
        }
    }

    private static let store = SCDynamicStoreCreate(nil, "Driftline" as CFString, nil, nil)

    static func primaryInterface() -> String? {
        guard let store = store,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any] else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    static func kind(of name: String?) -> Kind {
        guard let name else { return .offline }
        if CWWiFiClient.shared().interfaceNames()?.contains(name) == true { return .wifi }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("pdp_ip") { return .cellular }
        if name.hasPrefix("en") { return .ethernet }
        return .other
    }
}
