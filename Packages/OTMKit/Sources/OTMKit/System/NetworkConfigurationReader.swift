import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Reads `NetworkConfiguration` once, through public interfaces only:
/// SCDynamicStore for services, DNS and proxies, `getifaddrs` for addresses,
/// flags and MTU (`if_data`), `SIOCGIFXMEDIA` and `SIOCGIFAFLAG_IN6` for
/// media and IPv6 address flags, a `NET_RT_DUMP` sysctl for default routes,
/// CoreWLAN for the Wi-Fi channel, SCPreferences for the locations and the
/// mount table for network shares. Takes a few milliseconds; call it off
/// the main thread, when a page opens or on Refresh, never per tick.
public enum NetworkConfigurationReader {
    /// The store keys the configuration is built from: what's set up, and
    /// the state of each service and of the system as a whole.
    static let storePatterns = [
        "Setup:/Network/Global/IPv4",
        "Setup:/Network/Service/[^/]+(/(Interface|IPv4|IPv6|DNS))?",
        "State:/Network/Global/(IPv4|IPv6|DNS)",
        "State:/Network/Service/[^/]+/(IPv4|IPv6|DNS)",
    ]

    public static func read() -> NetworkConfiguration {
        var values: [String: Any] = [:]
        var proxies: [String: Any] = [:]
        if let store = SCDynamicStoreCreate(nil, "OpenTaskManager" as CFString, nil, nil) {
            values = SCDynamicStoreCopyMultiple(store, nil, storePatterns as CFArray) as? [String: Any] ?? [:]
            proxies = SCDynamicStoreCopyProxies(store) as? [String: Any] ?? [:]
        }
        let routes = Sysctl.bytes([CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP, 0]).map { buffer in
            DefaultRoute.parse(routingTable: buffer) { index in
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard index > 0, if_indextoname(UInt32(index), &name) != nil else { return nil }
                return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        } ?? []
        return NetworkConfiguration(store: values, proxies: proxies, interfaces: readInterfaces(), routes: routes,
                                    locations: NetworkLocation.read(), volumes: NetworkVolumeReader.read())
    }

    // MARK: - Interfaces

    private struct Partial {
        var flags: UInt32 = 0
        var mtu: Int?
        var addresses: [InterfaceAddress] = []
    }

    /// Every interface with its flags, MTU, media and addresses, in `getifaddrs` order.
    static func readInterfaces() -> [NetworkInterfaceDetails] {
        var order: [String] = []
        var partials: [String: Partial] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let socket4 = socket(AF_INET, SOCK_DGRAM, 0)
        let socket6 = socket(AF_INET6, SOCK_DGRAM, 0)
        defer {
            if socket4 >= 0 { close(socket4) }
            if socket6 >= 0 { close(socket6) }
        }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            if partials[name] == nil {
                order.append(name)
                partials[name] = Partial()
            }
            partials[name]?.flags = entry.pointee.ifa_flags
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    partials[name]?.mtu = Int(data.pointee.ifi_mtu)
                }
            case AF_INET, AF_INET6:
                if let parsed = interfaceAddress(entry.pointee, name: name, socket6: socket6) {
                    partials[name]?.addresses.append(parsed)
                }
            default:
                break
            }
        }
        let wifi = readWiFi()
        return order.map { name in
            let partial = partials[name] ?? Partial()
            return NetworkInterfaceDetails(name: name, flags: partial.flags, mtu: partial.mtu, media: readMedia(name, socket: socket4),
                                           addresses: partial.addresses, wifi: wifi[name])
        }
    }

    private static func interfaceAddress(_ entry: ifaddrs, name: String, socket6: Int32) -> InterfaceAddress? {
        guard let address = entry.ifa_addr else { return nil }
        let isIPv4 = Int32(address.pointee.sa_family) == AF_INET
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(isIPv4 ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let plain = text.split(separator: "%").first.map(String.init) ?? text
        let prefix = entry.ifa_netmask.flatMap { mask -> Int? in
            let raw = UnsafeRawPointer(mask)
            let start = isIPv4 ? 4 : 8
            let count = isIPv4 ? 4 : 16
            // The kernel cuts a netmask short after its last non-zero byte.
            let available = Int(mask.pointee.sa_len)
            let bytes = (0..<count).map { start + $0 < available ? raw.load(fromByteOffset: start + $0, as: UInt8.self) : 0 }
            return InterfaceAddress.prefixLength(mask: bytes)
        }
        if isIPv4 { return InterfaceAddress(family: .ipv4, address: plain, prefixLength: prefix) }
        let flags = ipv6Flags(address, name: name, socket: socket6)
        return InterfaceAddress(family: .ipv6, address: plain, prefixLength: prefix, isTemporary: flags & IN6_IFF_TEMPORARY != 0,
                                isDeprecated: flags & IN6_IFF_DEPRECATED != 0)
    }

    /// `_IOWR(group, number, size)` from `<sys/ioccom.h>`, which Swift can't import.
    private static func readWriteRequest(_ group: UInt8, _ number: UInt, size: Int) -> UInt {
        0xC000_0000 | (UInt(size & 0x1FFF) << 16) | (UInt(group) << 8) | number
    }

    private static func copyName(_ name: String, into tuple: UnsafeMutableRawBufferPointer) {
        for (index, byte) in name.utf8.prefix(tuple.count - 1).enumerated() { tuple[index] = byte }
    }

    /// An IPv6 address's flags (temporary, deprecated, secured…) from `SIOCGIFAFLAG_IN6`.
    private static func ipv6Flags(_ address: UnsafeMutablePointer<sockaddr>, name: String, socket: Int32) -> Int32 {
        guard socket >= 0 else { return 0 }
        var request = in6_ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { copyName(name, into: $0) }
        request.ifr_ifru.ifru_addr = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        let code = readWriteRequest(UInt8(ascii: "i"), 73, size: MemoryLayout<in6_ifreq>.size) // SIOCGIFAFLAG_IN6
        guard ioctl(socket, code, &request) == 0 else { return 0 }
        return request.ifr_ifru.ifru_flags6
    }

    /// The media words from `SIOCGIFXMEDIA`, which (unlike `SIOCGIFMEDIA`)
    /// keeps Ethernet's extended types. nil where there are no media.
    private static func readMedia(_ name: String, socket: Int32) -> NetworkMedia? {
        guard socket >= 0 else { return nil }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { copyName(name, into: $0) }
        let code = readWriteRequest(UInt8(ascii: "i"), 72, size: MemoryLayout<ifmediareq>.size) // SIOCGIFXMEDIA
        guard ioctl(socket, code, &request) == 0 else { return nil }
        return NetworkMedia(current: request.ifm_current, active: request.ifm_active, status: request.ifm_status)
    }

    // MARK: - Wi-Fi

    /// Channel, standard, signal and security for each Wi-Fi interface. The
    /// network's name (SSID) and base station (BSSID) are never asked for:
    /// on current macOS CoreWLAN only returns them to apps with Location
    /// Services access, and asking for that would raise a location prompt
    /// for a task manager, so they're left out rather than shown as missing.
    private static func readWiFi() -> [String: WiFiDetails] {
        var result: [String: WiFiDetails] = [:]
        for interface in CWWiFiClient.shared().interfaces() ?? [] {
            guard let name = interface.interfaceName, interface.powerOn() else { continue }
            let channel = interface.wlanChannel()
            let rate = interface.transmitRate()
            let associated = channel != nil
            result[name] = WiFiDetails(
                channel: channel?.channelNumber,
                band: channel.flatMap { WiFiDetails.band($0.channelBand.rawValue) },
                channelWidthMHz: channel.flatMap { WiFiDetails.channelWidth($0.channelWidth.rawValue) },
                standard: associated ? WiFiDetails.standard(phyMode: interface.activePHYMode().rawValue) : nil,
                rssi: associated ? interface.rssiValue() : nil,
                noise: associated ? interface.noiseMeasurement() : nil,
                transmitRateMbps: associated && rate > 0 ? rate : nil,
                security: associated ? WiFiDetails.security(interface.security().rawValue) : nil
            )
        }
        return result
    }
}
