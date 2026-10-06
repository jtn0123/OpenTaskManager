import Darwin
import Foundation
import SystemConfiguration

final class NetworkSampler {
    private struct Counters {
        let received: UInt64
        let sent: UInt64
    }

    private struct Metadata {
        var displayNames: [String: String] = [:]
        var kinds: [String: NetworkInterfaceKind] = [:]
        var addresses: [String: [String]] = [:]
        var refreshed = Date.distantPast
    }

    private var previous: [String: Counters] = [:]
    private var metadata = Metadata()

    func sample(interval: TimeInterval) -> [NetworkInterfaceSample] {
        // Names and addresses change rarely; refreshing them every few seconds
        // keeps per-tick work down to one sysctl.
        if Date().timeIntervalSince(metadata.refreshed) > 5 {
            metadata = Self.readMetadata()
        }

        var interfaces: [NetworkInterfaceSample] = []
        var seen: [String: Counters] = [:]

        for link in Self.readLinks() {
            let counters = Counters(received: link.received, sent: link.sent)
            seen[link.name] = counters
            let before = previous[link.name]
            func rate(_ now: UInt64, _ then: UInt64?) -> Double {
                guard let then, interval > 0, now >= then else { return 0 }
                return Double(now - then) / interval
            }
            interfaces.append(NetworkInterfaceSample(
                name: link.name,
                displayName: metadata.displayNames[link.name] ?? link.name,
                kind: metadata.kinds[link.name] ?? Self.guessKind(link.name, isLoopback: link.isLoopback),
                isUp: link.isUp,
                addresses: metadata.addresses[link.name] ?? [],
                linkSpeed: link.baudRate > 0 ? link.baudRate : nil,
                receivedBytesPerSecond: rate(link.received, before?.received),
                sentBytesPerSecond: rate(link.sent, before?.sent),
                totalReceived: link.received,
                totalSent: link.sent
            ))
        }

        previous = seen
        return interfaces
    }

    // MARK: - Counters

    private struct Link {
        let name: String
        let isUp: Bool
        let isLoopback: Bool
        let received: UInt64
        let sent: UInt64
        let baudRate: UInt64
    }

    /// Reads 64-bit interface counters. `getifaddrs` only exposes 32-bit
    /// counters that wrap every 4 GB, so this walks NET_RT_IFLIST2 instead.
    private static func readLinks() -> [Link] {
        guard let buffer = Sysctl.bytes([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]) else { return [] }
        var links: [Link] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= raw.count else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let flags = message.ifm_flags
                links.append(Link(
                    name: String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0,
                    received: message.ifm_data.ifi_ibytes,
                    sent: message.ifm_data.ifi_obytes,
                    baudRate: message.ifm_data.ifi_baudrate
                ))
            }
        }
        return links
    }

    // MARK: - Metadata

    private static func readMetadata() -> Metadata {
        var metadata = Metadata(refreshed: Date())
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                if let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                    metadata.displayNames[bsd] = name
                }
                if let type = SCNetworkInterfaceGetInterfaceType(interface) {
                    metadata.kinds[bsd] = kind(for: type)
                }
            }
        }
        metadata.addresses = readAddresses()
        return metadata
    }

    private static func kind(for type: CFString) -> NetworkInterfaceKind {
        switch type {
        case kSCNetworkInterfaceTypeIEEE80211: .wifi
        case kSCNetworkInterfaceTypeEthernet: .ethernet
        case kSCNetworkInterfaceTypeBond, kSCNetworkInterfaceTypeVLAN: .bridge
        case kSCNetworkInterfaceTypeWWAN: .cellular
        case kSCNetworkInterfaceTypePPP, kSCNetworkInterfaceTypeIPSec, kSCNetworkInterfaceTypeL2TP: .vpn
        default: .other
        }
    }

    static func guessKind(_ name: String, isLoopback: Bool) -> NetworkInterfaceKind {
        if isLoopback || name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("pdp_ip") { return .cellular }
        return .other
    }

    private static func readAddresses() -> [String: [String]] {
        var result: [String: [String]] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result[name, default: []].append(text)
        }
        // IPv4 first, then global IPv6, then link-local.
        return result.mapValues { list in
            list.sorted { rank($0) < rank($1) }
        }
    }

    private static func rank(_ address: String) -> Int {
        if !address.contains(":") { return 0 }
        return address.lowercased().hasPrefix("fe80") ? 2 : 1
    }
}
