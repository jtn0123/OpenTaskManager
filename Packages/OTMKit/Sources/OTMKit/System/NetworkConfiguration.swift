import Darwin
import Foundation

/// How this Mac's network is set up, read once for the System page: each
/// interface's addresses, MTU, flags and media; the services in System
/// Settings, in order; and what's in effect now: the primary interface, the
/// kernel's default routes, DNS, proxies and tunnels. What's configured (in
/// System Settings) is kept apart from what's operating now (on the
/// interfaces and in the routing table), since a diagnosis often turns on
/// the difference. `NetworkConfigurationReader` reads it; everything here is
/// pure, so tests build it from fixtures.
public struct NetworkConfiguration: Sendable, Hashable {
    /// Every interface `getifaddrs` lists, in its order, with the routers
    /// their services have now.
    public var interfaces: [NetworkInterfaceDetails]
    /// The services in System Settings, in their order, without the hidden
    /// ones macOS keeps for itself.
    public var services: [NetworkServiceInfo]
    /// The interface and service macOS sends traffic through by default now.
    public var primaryIPv4: NetworkPrimary?
    public var primaryIPv6: NetworkPrimary?
    /// Default routes in the kernel's table, scoped or not, and the halves
    /// of a split default route.
    public var defaultRoutes: [DefaultRoute]
    public var dns: DNSStatus
    public var proxies: ProxyStatus

    public init(interfaces: [NetworkInterfaceDetails], services: [NetworkServiceInfo], primaryIPv4: NetworkPrimary?,
                primaryIPv6: NetworkPrimary?, defaultRoutes: [DefaultRoute], dns: DNSStatus, proxies: ProxyStatus) {
        self.interfaces = interfaces
        self.services = services
        self.primaryIPv4 = primaryIPv4
        self.primaryIPv6 = primaryIPv6
        self.defaultRoutes = defaultRoutes
        self.dns = dns
        self.proxies = proxies
    }

    public func interface(_ name: String) -> NetworkInterfaceDetails? {
        interfaces.first { $0.name == name }
    }

    /// The configured service on this interface, if System Settings has one.
    public func service(on interface: String) -> NetworkServiceInfo? {
        services.first { $0.interface == interface }
    }

    /// The interface that carries traffic with no more specific route: one
    /// carrying both halves of a split default (0/1 and 128/1, as VPNs
    /// install them, which beat a plain default), else the one with the
    /// unscoped default. Scoped defaults only serve traffic bound to their
    /// interface, so they don't count. nil when there's no default route.
    public func defaultRouteInterface(_ family: InterfaceAddress.Family) -> String? {
        let routes = defaultRoutes.filter { $0.family == family && !$0.isScoped }
        let halves = Dictionary(grouping: routes.filter { $0.prefixLength == 1 }, by: \.interface)
        if let split = halves.first(where: { Set($0.value.map(\.destination)).count >= 2 })?.key { return split }
        return routes.first { $0.prefixLength == 0 }?.interface
    }

    /// VPN and tunnel interfaces (utun, ipsec, ppp), in name order.
    public var tunnels: [NetworkInterfaceDetails] {
        interfaces.filter(\.isTunnel).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The default service and interface, from `State:/Network/Global/IPv4` (or IPv6).
public struct NetworkPrimary: Sendable, Hashable {
    /// BSD name, "en0".
    public let interface: String
    public let serviceID: String?
    public let router: String?

    public init(interface: String, serviceID: String?, router: String?) {
        self.interface = interface
        self.serviceID = serviceID
        self.router = router
    }
}

// MARK: - Interfaces

public struct NetworkInterfaceDetails: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// `IFF_UP`, `IFF_RUNNING` and the rest.
    public let flags: UInt32
    public let mtu: Int?
    /// nil for interfaces without media (loopback, tunnels).
    public let media: NetworkMedia?
    public let addresses: [InterfaceAddress]
    /// On a Wi-Fi interface, what CoreWLAN gives without Location access.
    public var wifi: WiFiDetails?
    /// Operational: the routers its service has now.
    public var ipv4Router: String?
    public var ipv6Router: String?

    public init(name: String, flags: UInt32, mtu: Int?, media: NetworkMedia?, addresses: [InterfaceAddress], wifi: WiFiDetails? = nil,
                ipv4Router: String? = nil, ipv6Router: String? = nil) {
        self.name = name
        self.flags = flags
        self.mtu = mtu
        self.media = media
        self.addresses = addresses
        self.wifi = wifi
        self.ipv4Router = ipv4Router
        self.ipv6Router = ipv6Router
    }

    public var isUp: Bool { flags & UInt32(IFF_UP) != 0 }

    public var isTunnel: Bool {
        ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) }
    }

    /// Has an address other than a link-local one.
    public var hasRoutableAddress: Bool {
        addresses.contains { !$0.isLinkLocal }
    }

    /// The flags worth reading, as `ifconfig` names them but in words:
    /// "up", "running", "broadcast", "multicast"…
    public var flagNames: [String] {
        Self.flagNames(flags)
    }

    static let namedFlags: [(Int32, String)] = [
        (IFF_UP, "up"), (IFF_RUNNING, "running"), (IFF_BROADCAST, "broadcast"), (IFF_POINTOPOINT, "point-to-point"),
        (IFF_LOOPBACK, "loopback"), (IFF_MULTICAST, "multicast"), (IFF_SIMPLEX, "simplex"), (IFF_NOARP, "no ARP"),
        (IFF_PROMISC, "promiscuous"), (IFF_ALLMULTI, "all multicast"),
    ]

    public static func flagNames(_ flags: UInt32) -> [String] {
        namedFlags.filter { flags & UInt32($0.0) != 0 }.map(\.1)
    }
}

/// An IPv4 or IPv6 address on an interface, with its prefix.
public struct InterfaceAddress: Sendable, Hashable {
    public enum Family: String, Sendable, Codable {
        case ipv4, ipv6
    }

    public let family: Family
    /// Numeric, without a zone ("%en0").
    public let address: String
    /// From the netmask: 24 for 255.255.255.0.
    public let prefixLength: Int?
    /// IPv6 privacy addresses, which rotate; from `SIOCGIFAFLAG_IN6`.
    public let isTemporary: Bool
    /// Past its preferred lifetime: kept for existing connections only.
    public let isDeprecated: Bool

    public init(family: Family, address: String, prefixLength: Int?, isTemporary: Bool = false, isDeprecated: Bool = false) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
        self.isTemporary = isTemporary
        self.isDeprecated = isDeprecated
    }

    /// "192.168.1.9/24".
    public var withPrefix: String {
        prefixLength.map { "\(address)/\($0)" } ?? address
    }

    /// 169.254.0.0/16 or fe80::/10: usable only on the local link.
    public var isLinkLocal: Bool {
        switch family {
        case .ipv4: address.hasPrefix("169.254.")
        case .ipv6: address.lowercased().hasPrefix("fe8") || address.lowercased().hasPrefix("fe9")
            || address.lowercased().hasPrefix("fea") || address.lowercased().hasPrefix("feb")
        }
    }

    /// fc00::/7: an IPv6 address for the local network, not the Internet.
    public var isUniqueLocal: Bool {
        family == .ipv6 && (address.lowercased().hasPrefix("fc") || address.lowercased().hasPrefix("fd"))
    }

    /// The prefix a netmask's leading one bits make, or nil for a mask
    /// that isn't contiguous. Trailing bytes the kernel left off are zeros.
    public static func prefixLength(mask: [UInt8]) -> Int? {
        var length = 0
        var ended = false
        for byte in mask {
            if ended {
                if byte != 0 { return nil }
                continue
            }
            let ones = (~byte).leadingZeroBitCount
            // The ones must be leading: 0b1110_0000, not 0b1010_0000.
            if byte != 0, byte << ones != 0 { return nil }
            length += ones
            ended = ones < 8
        }
        return length
    }
}

/// An interface's media words from `SIOCGIFXMEDIA`: what's selected, what
/// was negotiated, and whether there's a carrier.
public struct NetworkMedia: Sendable, Hashable {
    /// Selected ("autoselect", or a fixed type).
    public let current: Int32
    /// Negotiated now.
    public let active: Int32
    public let status: Int32

    public init(current: Int32, active: Int32, status: Int32) {
        self.current = current
        self.active = active
        self.status = status
    }

    /// Whether a cable or network is attached; nil when the driver doesn't say.
    public var hasCarrier: Bool? {
        status & 0x1 != 0 ? status & 0x2 != 0 : nil // IFM_AVALID, IFM_ACTIVE
    }

    public var isEthernet: Bool { active & 0xE0 == 0x20 } // IFM_NMASK, IFM_ETHER

    /// The negotiated Ethernet type, "1000baseT"; nil for other media and
    /// for types this table doesn't name.
    public var activeType: String? {
        guard isEthernet else { return nil }
        return Self.ethernetTypes[Self.subtype(active)]
    }

    public var isAutoselect: Bool { Self.subtype(current) == 0 }

    /// "full-duplex", "flow control", "energy-efficient Ethernet".
    public var options: [String] {
        guard isEthernet else { return [] }
        let named: [(Int32, String)] = [(0x0010_0000, "full-duplex"), (0x0020_0000, "half-duplex"), (0x0040_0000, "flow control"),
                                        (0x0080_0000, "energy-efficient Ethernet")]
        return named.filter { active & $0.0 != 0 }.map(\.1)
    }

    /// "1000baseT, full-duplex (autoselect)", "No carrier", or nil when
    /// there's nothing beyond "autoselect" to say.
    public var summary: String? {
        if hasCarrier == false { return "No carrier" }
        guard let type = activeType, type != "autoselect" else { return nil }
        return ([type] + options).joined(separator: ", ") + (isAutoselect ? " (autoselect)" : "")
    }

    /// The media subtype, with the extended bits Ethernet uses past 31.
    static func subtype(_ word: Int32) -> Int {
        Int(word & 0x1F) | Int((word & 0x000F_0000) >> 11)
    }

    /// From `<net/if_media.h>`: the copper and common fibre types.
    static let ethernetTypes: [Int: String] = [
        0: "autoselect", 1: "manual", 2: "none", 3: "10baseT", 6: "100baseTX", 7: "100baseFX", 11: "1000baseSX",
        14: "1000baseLX", 15: "1000baseCX", 16: "1000baseT", 18: "10GbaseSR", 19: "10GbaseLR", 20: "10GbaseCX4",
        21: "10GbaseT", 22: "2500baseT", 23: "5000baseT", 32: "2500baseSX", 33: "10Gbase Twinax", 52: "100baseT",
        65: "25GbaseT",
    ]
}

/// A Wi-Fi interface's link, from CoreWLAN. The network's name (SSID) and
/// base station (BSSID) need Location Services access on current macOS,
/// which a task manager has no business asking for, so they're left out.
public struct WiFiDetails: Sendable, Hashable {
    public let channel: Int?
    /// "2.4 GHz", "5 GHz", "6 GHz".
    public let band: String?
    public let channelWidthMHz: Int?
    /// "802.11ax".
    public let standard: String?
    /// dBm.
    public let rssi: Int?
    public let noise: Int?
    public let transmitRateMbps: Double?
    /// "WPA3 Personal".
    public let security: String?

    public init(channel: Int?, band: String?, channelWidthMHz: Int?, standard: String?, rssi: Int?, noise: Int?,
                transmitRateMbps: Double?, security: String?) {
        self.channel = channel
        self.band = band
        self.channelWidthMHz = channelWidthMHz
        self.standard = standard
        self.rssi = rssi
        self.noise = noise
        self.transmitRateMbps = transmitRateMbps
        self.security = security
    }

    /// Whether a network is joined: CoreWLAN reports no channel otherwise.
    public var isAssociated: Bool { channel != nil }

    /// CoreWLAN's `CWPHYMode` raw values.
    public static func standard(phyMode: Int) -> String? {
        [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n (Wi-Fi 4)", 5: "802.11ac (Wi-Fi 5)", 6: "802.11ax (Wi-Fi 6)",
         7: "802.11be (Wi-Fi 7)"][phyMode]
    }

    /// `CWChannelBand` raw values.
    public static func band(_ raw: Int) -> String? {
        [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][raw]
    }

    /// `CWChannelWidth` raw values.
    public static func channelWidth(_ raw: Int) -> Int? {
        [1: 20, 2: 40, 3: 80, 4: 160][raw]
    }

    /// `CWSecurity` raw values.
    public static func security(_ raw: Int) -> String? {
        [0: "None", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal", 5: "Personal", 6: "Dynamic WEP",
         7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise", 9: "WPA2 Enterprise", 10: "Enterprise", 11: "WPA3 Personal",
         12: "WPA3 Enterprise", 13: "WPA2/WPA3 Personal", 14: "Enhanced Open", 15: "Enhanced Open (transition)"][raw]
    }
}

// MARK: - Services, DNS, proxies, routes

/// A service in System Settings' list, with what's configured for it and
/// whether it's up now.
public struct NetworkServiceInfo: Sendable, Hashable, Identifiable {
    public let id: String
    /// "Wi-Fi", "USB 10/100/1000 LAN".
    public let name: String
    /// BSD name of its interface.
    public let interface: String?
    /// Turned off with "Make Service Inactive".
    public let isEnabled: Bool
    /// Configured, as System Settings words it: "DHCP", "Manual"…
    public let ipv4Method: String?
    public let ipv6Method: String?
    /// DNS servers and search domains typed in for this service, which
    /// replace the network's.
    public let manualDNSServers: [String]
    public let manualSearchDomains: [String]
    /// Operational: it has an address now.
    public let isActive: Bool

    public init(id: String, name: String, interface: String?, isEnabled: Bool, ipv4Method: String?, ipv6Method: String?,
                manualDNSServers: [String] = [], manualSearchDomains: [String] = [], isActive: Bool) {
        self.id = id
        self.name = name
        self.interface = interface
        self.isEnabled = isEnabled
        self.ipv4Method = ipv4Method
        self.ipv6Method = ipv6Method
        self.manualDNSServers = manualDNSServers
        self.manualSearchDomains = manualSearchDomains
        self.isActive = isActive
    }

    /// "IPv4 by DHCP, IPv6 automatic".
    public var methodSummary: String? {
        let parts = [ipv4Method.map { "IPv4 " + Self.describe(ipv4: $0) }, ipv6Method.map { "IPv6 " + Self.describe(ipv6: $0) }]
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: ", ")
    }

    static func describe(ipv4 method: String) -> String {
        switch method {
        case "DHCP": "by DHCP"
        case "Manual": "manual"
        case "INFORM": "manual address, DHCP for the rest"
        case "BOOTP": "by BOOTP"
        case "LinkLocal": "link-local only"
        case "Automatic": "automatic"
        case "PPP": "by PPP"
        case "Off": "off"
        default: method
        }
    }

    static func describe(ipv6 method: String) -> String {
        switch method {
        case "Automatic", "RouterAdvertisement": "automatic"
        case "Manual": "manual"
        case "LinkLocal": "link-local only"
        case "6to4": "6to4"
        case "Off": "off"
        default: method
        }
    }
}

/// The resolver configuration in use now, and where it came from.
public struct DNSStatus: Sendable, Hashable {
    public enum Source: String, Sendable, Codable {
        /// Typed into System Settings for the service.
        case manual
        /// Handed out by the network (DHCP, router advertisements).
        case network
        /// Set by a VPN or tunnel.
        case vpn
    }

    public var servers: [String]
    public var searchDomains: [String]
    public var domainName: String?
    /// nil when no service's settings match what's in use.
    public var source: Source?
    /// The service the servers come from ("Wi-Fi"), and its interface.
    public var sourceService: String?
    public var sourceInterface: String?

    public init(servers: [String] = [], searchDomains: [String] = [], domainName: String? = nil, source: Source? = nil,
                sourceService: String? = nil, sourceInterface: String? = nil) {
        self.servers = servers
        self.searchDomains = searchDomains
        self.domainName = domainName
        self.source = source
        self.sourceService = sourceService
        self.sourceInterface = sourceInterface
    }

    /// The domains a short name is tried in: the search list, else the domain name.
    public var effectiveSearchDomains: [String] {
        searchDomains.isEmpty ? (domainName.map { [$0] } ?? []) : searchDomains
    }
}

/// The proxies in effect now (`SCDynamicStoreCopyProxies`).
public struct ProxyStatus: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case http, https, socks

        public var title: String {
            switch self {
            case .http: "HTTP"
            case .https: "HTTPS"
            case .socks: "SOCKS"
            }
        }
    }

    public struct Server: Sendable, Hashable {
        public let kind: Kind
        public let isEnabled: Bool
        public let host: String?
        public let port: Int?

        public init(kind: Kind, isEnabled: Bool, host: String?, port: Int?) {
            self.kind = kind
            self.isEnabled = isEnabled
            self.host = host
            self.port = port
        }

        /// "proxy.example.com:8080".
        public var endpoint: String? {
            host.map { host in port.map { "\(host):\($0)" } ?? host }
        }
    }

    /// One per kind, in `Kind` order.
    public var servers: [Server]
    public var autoConfigEnabled: Bool
    public var autoConfigURL: String?
    /// Web Proxy Auto-Discovery (WPAD).
    public var autoDiscoveryEnabled: Bool
    /// Hosts and domains that bypass the proxies.
    public var exceptions: [String]
    public var excludesSimpleHostnames: Bool

    public init(servers: [Server] = Kind.allCases.map { Server(kind: $0, isEnabled: false, host: nil, port: nil) },
                autoConfigEnabled: Bool = false, autoConfigURL: String? = nil, autoDiscoveryEnabled: Bool = false,
                exceptions: [String] = [], excludesSimpleHostnames: Bool = false) {
        self.servers = servers
        self.autoConfigEnabled = autoConfigEnabled
        self.autoConfigURL = autoConfigURL
        self.autoDiscoveryEnabled = autoDiscoveryEnabled
        self.exceptions = exceptions
        self.excludesSimpleHostnames = excludesSimpleHostnames
    }

    public var isAnyEnabled: Bool {
        servers.contains(where: \.isEnabled) || autoConfigEnabled || autoDiscoveryEnabled
    }

    public func server(_ kind: Kind) -> Server? {
        servers.first { $0.kind == kind }
    }

    /// The `SCDynamicStoreCopyProxies` dictionary, keyed as `scutil --proxy` prints it.
    public init(_ dictionary: [String: Any]) {
        func enabled(_ key: String) -> Bool { (dictionary[key] as? NSNumber)?.boolValue ?? false }
        func text(_ key: String) -> String? { (dictionary[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            servers: Kind.allCases.map { kind in
                let prefix = kind.rawValue.uppercased()
                return Server(kind: kind, isEnabled: enabled(prefix + "Enable"), host: text(prefix + "Proxy"),
                              port: (dictionary[prefix + "Port"] as? NSNumber)?.intValue)
            },
            autoConfigEnabled: enabled("ProxyAutoConfigEnable"),
            autoConfigURL: text("ProxyAutoConfigURLString"),
            autoDiscoveryEnabled: enabled("ProxyAutoDiscoveryEnable"),
            exceptions: dictionary["ExceptionsList"] as? [String] ?? [],
            excludesSimpleHostnames: enabled("ExcludeSimpleHostnames")
        )
    }
}

/// A route to everywhere, or half of everywhere, from the kernel's table.
public struct DefaultRoute: Sendable, Hashable {
    public let family: InterfaceAddress.Family
    /// BSD name of the interface it sends through.
    public let interface: String
    /// The next hop, when it's an address rather than the link itself.
    public let gateway: String?
    /// "0.0.0.0", "128.0.0.0", "::", "8000::".
    public let destination: String
    /// 0 for a default route, 1 for half of a split one.
    public let prefixLength: Int
    /// Bound to its interface (macOS keeps one per service), so only
    /// traffic sent through that interface uses it.
    public let isScoped: Bool

    public init(family: InterfaceAddress.Family, interface: String, gateway: String?, destination: String, prefixLength: Int,
                isScoped: Bool) {
        self.family = family
        self.interface = interface
        self.gateway = gateway
        self.destination = destination
        self.prefixLength = prefixLength
        self.isScoped = isScoped
    }
}

// MARK: - Parsing SCDynamicStore

extension NetworkConfiguration {
    /// Builds the configuration from SCDynamicStore's keys and values
    /// (`store`, "Setup:/Network/…" for what's configured and
    /// "State:/Network/…" for what's in effect, as `scutil` lists them), the
    /// proxies in effect, the interfaces and the kernel's default routes.
    public init(store: [String: Any], proxies: [String: Any], interfaces: [NetworkInterfaceDetails], routes: [DefaultRoute]) {
        let services = Self.parseServices(store)
        let primaryIPv4 = Self.primary(store["State:/Network/Global/IPv4"])
        let primaryIPv6 = Self.primary(store["State:/Network/Global/IPv6"])
        let primaryService = primaryIPv4?.serviceID ?? primaryIPv6?.serviceID
        self.init(
            interfaces: Self.addingRouters(store, to: interfaces, primaryService: primaryService),
            services: services,
            primaryIPv4: primaryIPv4,
            primaryIPv6: primaryIPv6,
            defaultRoutes: routes,
            dns: Self.parseDNS(store, services: services, primaryService: primaryService),
            proxies: ProxyStatus(proxies)
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [String] ?? []).filter { !$0.isEmpty }
    }

    /// Without a zone: SystemConfiguration writes IPv6 routers as "fe80::1%en0" at times.
    private static func unzoned(_ address: String?) -> String? {
        address.flatMap { $0.split(separator: "%").first.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func primary(_ value: Any?) -> NetworkPrimary? {
        guard let global = dictionary(value), let interface = global["PrimaryInterface"] as? String else { return nil }
        return NetworkPrimary(interface: interface, serviceID: global["PrimaryService"] as? String,
                              router: unzoned(global["Router"] as? String))
    }

    /// IDs from "Setup:/Network/Service/<id>" and its sub-keys.
    private static func serviceIDs(_ store: [String: Any], domain: String) -> Set<String> {
        let prefix = "\(domain):/Network/Service/"
        return Set(store.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return key.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
    }

    /// The configured services in System Settings' order, then any it
    /// doesn't order by name, leaving out the hidden ones.
    static func parseServices(_ store: [String: Any]) -> [NetworkServiceInfo] {
        let order = strings(dictionary(store["Setup:/Network/Global/IPv4"])?["ServiceOrder"])
        let known = serviceIDs(store, domain: "Setup")
        let unordered = known.subtracting(order)
        let ids = order.filter(known.contains) + unordered.sorted()
        return ids.compactMap { id -> NetworkServiceInfo? in
            let setup = "Setup:/Network/Service/\(id)"
            let base = dictionary(store[setup]) ?? [:]
            let interface = dictionary(store[setup + "/Interface"]) ?? [:]
            if (interface["HiddenConfiguration"] as? NSNumber)?.boolValue == true { return nil }
            let device = interface["DeviceName"] as? String
            let name = (base["UserDefinedName"] as? String) ?? (interface["UserDefinedName"] as? String) ?? device ?? id
            let dns = dictionary(store[setup + "/DNS"]) ?? [:]
            let state = "State:/Network/Service/\(id)"
            let active = [state + "/IPv4", state + "/IPv6"].contains { !strings(dictionary(store[$0])?["Addresses"]).isEmpty }
            return NetworkServiceInfo(
                id: id, name: name, interface: device, isEnabled: base["__INACTIVE__"] == nil,
                ipv4Method: dictionary(store[setup + "/IPv4"])?["ConfigMethod"] as? String,
                ipv6Method: dictionary(store[setup + "/IPv6"])?["ConfigMethod"] as? String,
                manualDNSServers: strings(dns["ServerAddresses"]), manualSearchDomains: strings(dns["SearchDomains"]),
                isActive: active
            )
        }
    }

    /// Each interface's routers, from the state of the service on it (a
    /// VPN's service has no settings, only state). The primary service wins
    /// where two claim an interface.
    private static func addingRouters(_ store: [String: Any], to interfaces: [NetworkInterfaceDetails],
                                      primaryService: String?) -> [NetworkInterfaceDetails] {
        var routers: [String: (ipv4: String?, ipv6: String?)] = [:]
        let ids = serviceIDs(store, domain: "State").sorted { ($0 == primaryService ? 0 : 1, $0) < ($1 == primaryService ? 0 : 1, $1) }
        for id in ids {
            for (family, key) in [(InterfaceAddress.Family.ipv4, "IPv4"), (.ipv6, "IPv6")] {
                guard let state = dictionary(store["State:/Network/Service/\(id)/\(key)"]),
                      let name = state["InterfaceName"] as? String, let router = unzoned(state["Router"] as? String) else { continue }
                // "fe80::" alone, as tunnels report it, isn't a router anyone can reach.
                if router == "fe80::" { continue }
                var entry = routers[name] ?? (nil, nil)
                if family == .ipv4, entry.ipv4 == nil { entry.ipv4 = router }
                if family == .ipv6, entry.ipv6 == nil { entry.ipv6 = router }
                routers[name] = entry
            }
        }
        return interfaces.map { details in
            var details = details
            details.ipv4Router = routers[details.name]?.ipv4 ?? details.ipv4Router
            details.ipv6Router = routers[details.name]?.ipv6 ?? details.ipv6Router
            return details
        }
    }

    /// The servers and domains in use, and the service whose settings
    /// match them: the primary service's manual servers, else the first
    /// service (the primary one first) whose state hands out the same
    /// servers. A VPN's split-DNS resolvers (with match domains) don't count.
    static func parseDNS(_ store: [String: Any], services: [NetworkServiceInfo], primaryService: String?) -> DNSStatus {
        let global = dictionary(store["State:/Network/Global/DNS"]) ?? [:]
        var status = DNSStatus(servers: strings(global["ServerAddresses"]), searchDomains: strings(global["SearchDomains"]),
                               domainName: (global["DomainName"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        guard !status.servers.isEmpty else { return status }
        if let primaryService, let service = services.first(where: { $0.id == primaryService }), !service.manualDNSServers.isEmpty {
            status.source = .manual
            status.sourceService = service.name
            status.sourceInterface = service.interface
            return status
        }
        let ids = serviceIDs(store, domain: "State").sorted { ($0 == primaryService ? 0 : 1, $0) < ($1 == primaryService ? 0 : 1, $1) }
        for id in ids {
            let state = "State:/Network/Service/\(id)"
            guard let dns = dictionary(store[state + "/DNS"]), strings(dns["SupplementalMatchDomains"]).isEmpty,
                  Set(strings(dns["ServerAddresses"])) == Set(status.servers) else { continue }
            let service = services.first { $0.id == id }
            let interface = (dns["InterfaceName"] as? String)
                ?? (dictionary(store[state + "/IPv4"])?["InterfaceName"] as? String)
                ?? (dictionary(store[state + "/IPv6"])?["InterfaceName"] as? String)
                ?? service?.interface
            let isTunnel = interface.map { name in ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) } } ?? false
            status.source = isTunnel ? .vpn : .network
            status.sourceService = service?.name
            status.sourceInterface = interface
            return status
        }
        return status
    }
}

// MARK: - Parsing the routing table

extension DefaultRoute {
    /// The default routes (0/0) and split-default halves (0/1, 128/1 and
    /// their IPv6 equivalents) in a `NET_RT_DUMP` sysctl buffer: `rt_msghdr`
    /// records, each followed by the socket addresses its `rtm_addrs` bits
    /// name. `interfaceName` turns an interface index into its BSD name.
    public static func parse(routingTable buffer: [UInt8], interfaceName: (Int) -> String?) -> [DefaultRoute] {
        var routes: [DefaultRoute] = []
        let headerSize = MemoryLayout<rt_msghdr>.size
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length >= headerSize, offset + length <= raw.count else { break }
                defer { offset += length }
                let flags = header.rtm_flags
                guard flags & RTF_UP != 0, flags & (RTF_HOST | RTF_REJECT | RTF_BLACKHOLE) == 0,
                      let name = interfaceName(Int(header.rtm_index)) else { continue }
                let addresses = socketAddresses(raw, from: offset + headerSize, to: offset + length, present: header.rtm_addrs)
                guard let destination = addresses[RTA_DST], let family = family(destination),
                      let mask = addresses[RTA_NETMASK] else { continue }
                let width = family == .ipv4 ? 4 : 16
                let destinationBytes = addressBytes(destination, family: family, count: width)
                guard let prefix = InterfaceAddress.prefixLength(mask: addressBytes(mask, family: family, count: width)),
                      prefix <= 1, destinationBytes.dropFirst().allSatisfy({ $0 == 0 }),
                      destinationBytes[0] == 0 || (prefix == 1 && destinationBytes[0] == 0x80) else { continue }
                routes.append(DefaultRoute(
                    family: family, interface: name,
                    gateway: addresses[RTA_GATEWAY].flatMap { gateway in self.family(gateway) == family ? text(gateway, family: family) : nil },
                    destination: text(destination, family: family) ?? "", prefixLength: prefix,
                    isScoped: flags & RTF_IFSCOPE != 0
                ))
            }
        }
        return routes
    }

    /// The socket addresses after a header, by their `RTA_` bit. Each is
    /// padded to 4 bytes, and an empty one (a /0 netmask) still takes 4.
    private static func socketAddresses(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int, present: Int32) -> [Int32: [UInt8]] {
        var result: [Int32: [UInt8]] = [:]
        var cursor = start
        for bit in 0..<Int32(RTAX_MAX) where present & (1 << bit) != 0 {
            guard cursor < end else { break }
            let length = Int(raw[cursor])
            let padded = length > 0 ? 1 + ((length - 1) | 3) : 4
            result[1 << bit] = Array(raw[cursor..<min(cursor + max(length, 1), end)])
            cursor += padded
        }
        return result
    }

    private static func family(_ address: [UInt8]) -> InterfaceAddress.Family? {
        guard address.count > 1 else { return nil }
        switch Int32(address[1]) {
        case AF_INET: return .ipv4
        case AF_INET6: return .ipv6
        default: return nil
        }
    }

    /// The address bytes of a socket address, zero-filled where the kernel
    /// cut a netmask short. They start at 4 in a `sockaddr_in` and 8 in a
    /// `sockaddr_in6`.
    private static func addressBytes(_ address: [UInt8], family: InterfaceAddress.Family, count: Int) -> [UInt8] {
        let start = family == .ipv4 ? 4 : 8
        return (0..<count).map { start + $0 < address.count ? address[start + $0] : 0 }
    }

    private static func text(_ address: [UInt8], family: InterfaceAddress.Family) -> String? {
        var bytes = addressBytes(address, family: family, count: family == .ipv4 ? 4 : 16)
        // The kernel keeps a link-local address's zone in its second 16 bits.
        if family == .ipv6, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            bytes[2] = 0
            bytes[3] = 0
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { source in
            inet_ntop(family == .ipv4 ? AF_INET : AF_INET6, source.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        return ok ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }
}
