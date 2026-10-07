import Foundation

/// The report's `network` ports and its `networkConfiguration`. Ports and
/// the top-level fields are the state in effect now; `services` is what's
/// configured in System Settings, each with whether it's up now. Addresses,
/// routers, gateways, DNS servers, search domains and proxy hosts are
/// identifiers: `null` unless they're included.
extension SystemReportJSON {
    struct NetworkPort: Encodable {
        /// BSD name, such as "en0".
        let name: String
        let displayName: String
        let kind: NetworkInterfaceKind
        let isUp: Bool
        /// Carries the primary service: macOS sends traffic through it by default.
        let isPrimary: Bool
        /// IPv4 first, then IPv6.
        @Nullable var addresses: [String]?
        /// The same addresses with their prefixes and IPv6 flags; null where
        /// the configuration wasn't read.
        @Nullable var addressDetails: [NetworkAddress]?
        /// The routers its service has now.
        @Nullable var ipv4Router: String?
        @Nullable var ipv6Router: String?
        @Nullable var hardwareAddress: String?
        @Nullable var linkSpeedBitsPerSecond: UInt64?
        @Nullable var mtu: Int?
        /// "up", "running", "broadcast", "multicast"…
        @Nullable var flags: [String]?
        /// The negotiated Ethernet media: "1000baseT, full-duplex (autoselect)", or "No carrier".
        @Nullable var media: String?
        /// Never the network's name: that needs Location Services.
        @Nullable var wifi: WiFi?
        /// The System Settings service on it ("Wi-Fi").
        @Nullable var service: String?

        init(_ port: NetworkPortInfo, configuration: NetworkConfiguration?, keep: Bool) {
            let details = configuration?.interface(port.name)
            name = port.name
            displayName = port.displayName
            kind = port.kind
            isUp = port.isUp
            isPrimary = configuration.map { ($0.primaryIPv4?.interface ?? $0.primaryIPv6?.interface) == port.name } ?? false
            addresses = keep ? port.addresses : nil
            addressDetails = keep ? details?.addresses.map(NetworkAddress.init) : nil
            ipv4Router = keep ? details?.ipv4Router : nil
            ipv6Router = keep ? details?.ipv6Router : nil
            hardwareAddress = keep ? port.hardwareAddress : nil
            linkSpeedBitsPerSecond = port.linkSpeed
            mtu = details?.mtu
            flags = details?.flagNames
            media = details?.media.flatMap { $0.isEthernet ? $0.summary : nil }
            wifi = details?.wifi.map(WiFi.init)
            service = configuration?.service(on: port.name)?.name
        }
    }

    struct NetworkAddress: Encodable {
        let family: InterfaceAddress.Family
        let address: String
        @Nullable var prefixLength: Int?
        let isLinkLocal: Bool
        /// An IPv6 privacy address, which rotates.
        let isTemporary: Bool
        /// Past its preferred lifetime: kept only for connections already open.
        let isDeprecated: Bool

        init(_ address: InterfaceAddress) {
            family = address.family
            self.address = address.address
            prefixLength = address.prefixLength
            isLinkLocal = address.isLinkLocal
            isTemporary = address.isTemporary
            isDeprecated = address.isDeprecated
        }
    }

    struct WiFi: Encodable {
        @Nullable var channel: Int?
        /// "2.4 GHz", "5 GHz", "6 GHz".
        @Nullable var band: String?
        @Nullable var channelWidthMHz: Int?
        /// "802.11ax (Wi-Fi 6)".
        @Nullable var standard: String?
        @Nullable var rssiDBm: Int?
        @Nullable var noiseDBm: Int?
        @Nullable var transmitRateMbps: Double?
        /// "WPA3 Personal".
        @Nullable var security: String?

        init(_ wifi: WiFiDetails) {
            channel = wifi.channel
            band = wifi.band
            channelWidthMHz = wifi.channelWidthMHz
            standard = wifi.standard
            rssiDBm = wifi.rssi
            noiseDBm = wifi.noise
            transmitRateMbps = SystemReportJSON.finite(wifi.transmitRateMbps)
            security = wifi.security
        }
    }

    /// What the whole Mac uses now, then the services as configured.
    struct NetworkSetup: Encodable {
        /// The interface and service of `State:/Network/Global/IPv4` (and IPv6).
        @Nullable var primaryInterface: String?
        @Nullable var primaryIPv6Interface: String?
        @Nullable var primaryService: String?
        @Nullable var router: String?
        @Nullable var ipv6Router: String?
        /// Where traffic with no more specific route goes: a split default
        /// (0/1 and 128/1, as VPNs add) wins over a plain one.
        @Nullable var defaultRouteInterface: String?
        @Nullable var ipv6DefaultRouteInterface: String?
        /// Every default route and split-default half in the kernel's table.
        let defaultRoutes: [NetworkRoute]
        let tunnels: [NetworkTunnel]
        let dns: NetworkDNS
        let proxies: NetworkProxies
        /// Configured: System Settings' services, in its order.
        let services: [NetworkService]
        /// Configured: System Settings' locations, the one in use first.
        let locations: [NetworkLocationJSON]
        /// Shares mounted from servers now, from the mount table.
        let volumes: [NetworkVolumeJSON]

        init(_ configuration: NetworkConfiguration, keep: Bool) {
            primaryInterface = configuration.primaryIPv4?.interface
            primaryIPv6Interface = configuration.primaryIPv6?.interface
            let serviceID = configuration.primaryIPv4?.serviceID ?? configuration.primaryIPv6?.serviceID
            primaryService = configuration.services.first { $0.id == serviceID }?.name
            router = keep ? configuration.primaryIPv4?.router : nil
            ipv6Router = keep ? configuration.primaryIPv6?.router : nil
            let ipv4 = configuration.defaultRouteInterface(.ipv4)
            let ipv6 = configuration.defaultRouteInterface(.ipv6)
            defaultRouteInterface = ipv4
            ipv6DefaultRouteInterface = ipv6
            defaultRoutes = configuration.defaultRoutes.map { NetworkRoute($0, keep: keep) }
            tunnels = configuration.tunnels.map { tunnel in
                NetworkTunnel(name: tunnel.name, isUp: tunnel.isUp, hasRoutableAddress: tunnel.hasRoutableAddress,
                              carriesDefaultRoute: tunnel.name == ipv4 || tunnel.name == ipv6)
            }
            dns = NetworkDNS(configuration.dns, keep: keep)
            proxies = NetworkProxies(configuration.proxies, keep: keep)
            services = configuration.services.map { NetworkService($0, keep: keep) }
            locations = configuration.locations.map(NetworkLocationJSON.init)
            volumes = configuration.volumes.map { NetworkVolumeJSON($0, keep: keep) }
        }
    }

    struct NetworkRoute: Encodable {
        let family: InterfaceAddress.Family
        let interface: String
        /// "0.0.0.0", or "128.0.0.0" for half of a split default.
        let destination: String
        let prefixLength: Int
        /// Bound to its interface: only traffic sent through it uses the route.
        let isScoped: Bool
        @Nullable var gateway: String?

        init(_ route: DefaultRoute, keep: Bool) {
            family = route.family
            interface = route.interface
            destination = route.destination
            prefixLength = route.prefixLength
            isScoped = route.isScoped
            gateway = keep ? route.gateway : nil
        }
    }

    struct NetworkTunnel: Encodable {
        let name: String
        let isUp: Bool
        /// False for the link-local-only tunnels macOS keeps for its own services.
        let hasRoutableAddress: Bool
        let carriesDefaultRoute: Bool
    }

    struct NetworkDNS: Encodable {
        /// Counts stay when the servers and domains are left out.
        let serverCount: Int
        @Nullable var servers: [String]?
        let searchDomainCount: Int
        @Nullable var searchDomains: [String]?
        @Nullable var domainName: String?
        /// "manual", "network" or "vpn"; null when no service's settings match.
        @Nullable var source: DNSStatus.Source?
        @Nullable var sourceService: String?
        @Nullable var sourceInterface: String?

        init(_ dns: DNSStatus, keep: Bool) {
            serverCount = dns.servers.count
            servers = keep ? dns.servers : nil
            searchDomainCount = dns.searchDomains.count
            searchDomains = keep ? dns.searchDomains : nil
            domainName = keep ? dns.domainName : nil
            source = dns.source
            sourceService = dns.sourceService
            sourceInterface = dns.sourceInterface
        }
    }

    struct NetworkProxies: Encodable {
        let http: NetworkProxy
        let https: NetworkProxy
        let socks: NetworkProxy
        let autoConfigEnabled: Bool
        @Nullable var autoConfigURL: String?
        let autoDiscoveryEnabled: Bool
        @Nullable var exceptions: [String]?
        let excludesSimpleHostnames: Bool

        init(_ proxies: ProxyStatus, keep: Bool) {
            func server(_ kind: ProxyStatus.Kind) -> NetworkProxy {
                let entry = proxies.server(kind)
                return NetworkProxy(isEnabled: entry?.isEnabled ?? false, host: keep ? entry?.host : nil, port: entry?.port)
            }
            http = server(.http)
            https = server(.https)
            socks = server(.socks)
            autoConfigEnabled = proxies.autoConfigEnabled
            autoConfigURL = keep ? proxies.autoConfigURL : nil
            autoDiscoveryEnabled = proxies.autoDiscoveryEnabled
            exceptions = keep ? proxies.exceptions : nil
            excludesSimpleHostnames = proxies.excludesSimpleHostnames
        }
    }

    struct NetworkProxy: Encodable {
        let isEnabled: Bool
        @Nullable var host: String?
        @Nullable var port: Int?

        init(isEnabled: Bool, host: String?, port: Int?) {
            self.isEnabled = isEnabled
            self.host = host
            self.port = port
        }
    }

    struct NetworkService: Encodable {
        let name: String
        @Nullable var interface: String?
        /// False once "Make Service Inactive" is chosen.
        let isEnabled: Bool
        /// Operational: it has an address now.
        let isActive: Bool
        /// As System Settings stores it: "DHCP", "Manual", "Automatic"…
        @Nullable var ipv4ConfigMethod: String?
        @Nullable var ipv6ConfigMethod: String?
        @Nullable var manualDNSServers: [String]?
        @Nullable var manualSearchDomains: [String]?

        init(_ service: NetworkServiceInfo, keep: Bool) {
            name = service.name
            interface = service.interface
            isEnabled = service.isEnabled
            isActive = service.isActive
            ipv4ConfigMethod = service.ipv4Method
            ipv6ConfigMethod = service.ipv6Method
            manualDNSServers = keep ? service.manualDNSServers : nil
            manualSearchDomains = keep ? service.manualSearchDomains : nil
        }
    }

    /// The network part alone, for `otm netconfig --json`.
    struct NetworkOnly: Encodable {
        let format = SystemReportDocument.format
        let schemaVersion = SystemReportDocument.schemaVersion
        let collectedAt: Date
        let includesIdentifiers: Bool
        let network: [NetworkPort]
        @Nullable var networkConfiguration: NetworkSetup?
        @Nullable var firewall: Firewall?

        init(collectedAt: Date, includesIdentifiers: Bool, network: [NetworkPort], networkConfiguration: NetworkSetup?,
             firewall: Firewall?) {
            self.collectedAt = collectedAt
            self.includesIdentifiers = includesIdentifiers
            self.network = network
            self.networkConfiguration = networkConfiguration
            self.firewall = firewall
        }
    }
}

extension SystemReportDocument {
    /// The report's `network`, `networkConfiguration` and `firewall` fields
    /// alone, with the same header, as `otm netconfig --json` prints them.
    public static func networkJSON(_ ports: [NetworkPortInfo], configuration: NetworkConfiguration?, firewall: FirewallStatus? = nil,
                                   includeIdentifiers keep: Bool, collectedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let report = SystemReportJSON.NetworkOnly(
            collectedAt: collectedAt, includesIdentifiers: keep,
            network: ports.filter(\.isWorthListing).map { SystemReportJSON.NetworkPort($0, configuration: configuration, keep: keep) },
            networkConfiguration: configuration.map { SystemReportJSON.NetworkSetup($0, keep: keep) },
            firewall: firewall.map(SystemReportJSON.Firewall.init)
        )
        return try encoder.encode(report)
    }
}
