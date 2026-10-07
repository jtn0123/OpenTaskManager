import Darwin
import Foundation
@testable import OTMKit
import Testing

/// A Mac on Wi-Fi (primary, DHCP) with a wired port up beside it that has
/// DNS typed in, an inactive Thunderbolt Bridge, a VPN on utun4 holding a
/// split default route and a split-DNS resolver, and a link-local tunnel
/// macOS keeps for itself. Shaped like `scutil` and `getifaddrs` report it.
enum NetworkFixture {
    static let wifiID = "F82BBE4E-2A7E-4D60-BDD8-3D83E7968C31"
    static let ethernetID = "6D34ABB2-3507-4ECE-8292-C9B8753E7F11"
    static let bridgeID = "C1C5F137-418F-44B9-A11B-A2109816CA53"
    static let hiddenID = "8D6EF9BC-F87F-4AED-A5DA-A0EE275C53CB"
    static let vpnID = "33941D3F-43DD-4682-873E-C34DFB224FEB"

    static var yes: NSNumber { NSNumber(value: true) }

    static var store: [String: Any] { [
        "Setup:/Network/Global/IPv4": ["ServiceOrder": [wifiID, ethernetID, bridgeID, hiddenID]],
        "Setup:/Network/Service/\(wifiID)": ["UserDefinedName": "Wi-Fi"],
        "Setup:/Network/Service/\(wifiID)/Interface": ["DeviceName": "en0", "Hardware": "AirPort", "UserDefinedName": "Wi-Fi"],
        "Setup:/Network/Service/\(wifiID)/IPv4": ["ConfigMethod": "DHCP"],
        "Setup:/Network/Service/\(wifiID)/IPv6": ["ConfigMethod": "Automatic"],
        "Setup:/Network/Service/\(ethernetID)": ["UserDefinedName": "USB 10/100/1000 LAN"],
        "Setup:/Network/Service/\(ethernetID)/Interface": ["DeviceName": "en7", "Hardware": "Ethernet"],
        "Setup:/Network/Service/\(ethernetID)/IPv4": ["ConfigMethod": "DHCP"],
        "Setup:/Network/Service/\(ethernetID)/DNS": ["ServerAddresses": ["9.9.9.9"], "SearchDomains": ["corp.example"]],
        "Setup:/Network/Service/\(bridgeID)": ["UserDefinedName": "Thunderbolt Bridge", "__INACTIVE__": NSNumber(value: 1)],
        "Setup:/Network/Service/\(bridgeID)/Interface": ["DeviceName": "bridge0"],
        "Setup:/Network/Service/\(bridgeID)/IPv4": ["ConfigMethod": "DHCP"],
        "Setup:/Network/Service/\(hiddenID)/Interface": ["DeviceName": "en5", "HiddenConfiguration": yes],
        "State:/Network/Global/IPv4": ["PrimaryInterface": "en0", "PrimaryService": wifiID, "Router": "192.168.1.1"],
        "State:/Network/Global/IPv6": ["PrimaryInterface": "en0", "PrimaryService": wifiID, "Router": "fe80::1%en0"],
        "State:/Network/Global/DNS": ["ServerAddresses": ["192.168.1.1", "2001:db8::1"], "SearchDomains": ["home.arpa"]],
        "State:/Network/Service/\(wifiID)/IPv4": ["Addresses": ["192.168.1.9"], "InterfaceName": "en0", "Router": "192.168.1.1",
                                                  "SubnetMasks": ["255.255.255.0"]],
        "State:/Network/Service/\(wifiID)/IPv6": ["Addresses": ["2001:db8::5"], "InterfaceName": "en0", "Router": "fe80::1%en0"],
        "State:/Network/Service/\(wifiID)/DNS": ["ServerAddresses": ["2001:db8::1", "192.168.1.1"], "SearchDomains": ["home.arpa"]],
        "State:/Network/Service/\(ethernetID)/IPv4": ["Addresses": ["10.0.0.5"], "InterfaceName": "en7", "Router": "10.0.0.1"],
        "State:/Network/Service/\(ethernetID)/DNS": ["ServerAddresses": ["9.9.9.9"]],
        "State:/Network/Service/\(vpnID)/IPv4": ["Addresses": ["10.8.0.2"], "InterfaceName": "utun4", "Router": "10.8.0.2"],
        "State:/Network/Service/\(vpnID)/IPv6": ["Addresses": ["fe80::abcd"], "InterfaceName": "utun4", "Router": "fe80::"],
        // Split DNS: only for its match domain, so it isn't what the Mac uses.
        "State:/Network/Service/\(vpnID)/DNS": ["ServerAddresses": ["10.8.0.1"], "SupplementalMatchDomains": ["corp.example"]],
    ] }

    static var proxies: [String: Any] { [
        "HTTPEnable": NSNumber(value: 0), "HTTPProxy": "proxy.corp.example", "HTTPPort": NSNumber(value: 8080),
        "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.corp.example", "HTTPSPort": NSNumber(value: 8443),
        "SOCKSEnable": NSNumber(value: 0),
        "ProxyAutoConfigEnable": NSNumber(value: 1), "ProxyAutoConfigURLString": "http://wpad.corp.example/proxy.pac",
        "ExceptionsList": ["*.local", "169.254/16"], "ExcludeSimpleHostnames": NSNumber(value: 1),
    ] }

    static let ethernetFlags = UInt32(IFF_UP | IFF_BROADCAST | IFF_NOTRAILERS | IFF_RUNNING | IFF_SIMPLEX | IFF_MULTICAST)
    static let tunnelFlags = UInt32(IFF_UP | IFF_POINTOPOINT | IFF_RUNNING | IFF_MULTICAST)

    static func address(_ text: String, _ prefix: Int, temporary: Bool = false, deprecated: Bool = false) -> InterfaceAddress {
        InterfaceAddress(family: text.contains(":") ? .ipv6 : .ipv4, address: text, prefixLength: prefix, isTemporary: temporary,
                         isDeprecated: deprecated)
    }

    static let wifi = WiFiDetails(channel: 36, band: "5 GHz", channelWidthMHz: 80, standard: "802.11ax (Wi-Fi 6)", rssi: -52, noise: -94,
                                  transmitRateMbps: 866, security: "WPA3 Personal")

    static let interfaces = [
        NetworkInterfaceDetails(name: "lo0", flags: UInt32(IFF_UP | IFF_LOOPBACK | IFF_RUNNING | IFF_MULTICAST), mtu: 16_384, media: nil,
                                addresses: [address("127.0.0.1", 8), address("::1", 128)]),
        NetworkInterfaceDetails(
            name: "en0", flags: ethernetFlags, mtu: 1500, media: NetworkMedia(current: 0x80, active: 0x80, status: 3),
            addresses: [
                address("fe80::1c", 64), address("192.168.1.9", 24), address("2001:db8::5", 64),
                address("2001:db8::77", 64, temporary: true), address("2001:db8::66", 64, temporary: true, deprecated: true),
            ],
            wifi: wifi
        ),
        // 1000baseT (16), full-duplex, chosen by autoselect, with a carrier.
        NetworkInterfaceDetails(name: "en7", flags: ethernetFlags, mtu: 1500,
                                media: NetworkMedia(current: 0x20, active: 0x20 | 16 | 0x0010_0000, status: 3),
                                addresses: [address("10.0.0.5", 24)]),
        NetworkInterfaceDetails(name: "utun0", flags: tunnelFlags, mtu: 1380, media: nil, addresses: [address("fe80::ce81", 64)]),
        NetworkInterfaceDetails(name: "utun4", flags: tunnelFlags, mtu: 1420, media: nil,
                                addresses: [address("10.8.0.2", 24), address("fe80::abcd", 64)]),
    ]

    static let routes = [
        DefaultRoute(family: .ipv4, interface: "en0", gateway: "192.168.1.1", destination: "0.0.0.0", prefixLength: 0, isScoped: false),
        DefaultRoute(family: .ipv4, interface: "en7", gateway: "10.0.0.1", destination: "0.0.0.0", prefixLength: 0, isScoped: true),
        DefaultRoute(family: .ipv4, interface: "utun4", gateway: nil, destination: "0.0.0.0", prefixLength: 1, isScoped: false),
        DefaultRoute(family: .ipv4, interface: "utun4", gateway: nil, destination: "128.0.0.0", prefixLength: 1, isScoped: false),
        DefaultRoute(family: .ipv6, interface: "en0", gateway: "fe80::1", destination: "::", prefixLength: 0, isScoped: false),
        DefaultRoute(family: .ipv6, interface: "utun0", gateway: nil, destination: "::", prefixLength: 0, isScoped: true),
    ]

    static let configuration = NetworkConfiguration(store: store, proxies: proxies, interfaces: interfaces, routes: routes)

    /// The ports as `SystemInfoReader.readNetwork` lists them.
    static let ports = [
        NetworkPortInfo(name: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true,
                        addresses: ["192.168.1.9", "2001:db8::5", "2001:db8::77", "2001:db8::66", "fe80::1c"],
                        hardwareAddress: "a4:83:e7:0b:12:9c", linkSpeed: 53_950_000),
        NetworkPortInfo(name: "en7", displayName: "USB 10/100/1000 LAN", kind: .ethernet, isUp: true, addresses: ["10.0.0.5"],
                        hardwareAddress: "00:e0:4c:68:01:02", linkSpeed: 1_000_000_000),
        NetworkPortInfo(name: "utun0", displayName: "utun0", kind: .vpn, isUp: true, addresses: ["fe80::ce81"], hardwareAddress: nil,
                        linkSpeed: nil),
        NetworkPortInfo(name: "utun4", displayName: "utun4", kind: .vpn, isUp: true, addresses: ["10.8.0.2", "fe80::abcd"],
                        hardwareAddress: nil, linkSpeed: nil),
    ]
}

/// Parsing SCDynamicStore, proxies, media, flags and the routing table into
/// `NetworkConfiguration`, from fixtures rather than this Mac's network.
struct NetworkConfigurationTests {
    private let configuration = NetworkFixture.configuration

    @Test func servicesFollowSystemSettingsOrderWithoutHiddenOnes() {
        let services = configuration.services
        #expect(services.map(\.name) == ["Wi-Fi", "USB 10/100/1000 LAN", "Thunderbolt Bridge"])
        #expect(services.map(\.interface) == ["en0", "en7", "bridge0"])
        #expect(services.map(\.isEnabled) == [true, true, false])
        // Operational, from State: an address now.
        #expect(services.map(\.isActive) == [true, true, false])
        #expect(services[0].methodSummary == "IPv4 by DHCP, IPv6 automatic")
        #expect(services[1].manualDNSServers == ["9.9.9.9"])
        #expect(services[1].manualSearchDomains == ["corp.example"])
        #expect(configuration.service(on: "en7")?.name == "USB 10/100/1000 LAN")
        #expect(configuration.service(on: "utun4") == nil)
    }

    @Test func servicesSystemSettingsDoesNotOrderComeLast() {
        var store = NetworkFixture.store
        store["Setup:/Network/Global/IPv4"] = ["ServiceOrder": [NetworkFixture.ethernetID]]
        let names = NetworkConfiguration.parseServices(store).map(\.name)
        #expect(names.first == "USB 10/100/1000 LAN")
        #expect(Set(names) == ["Wi-Fi", "USB 10/100/1000 LAN", "Thunderbolt Bridge"])
    }

    @Test func primaryServiceAndRoutersComeFromState() {
        #expect(configuration.primaryIPv4 == NetworkPrimary(interface: "en0", serviceID: NetworkFixture.wifiID, router: "192.168.1.1"))
        // The zone SystemConfiguration adds to a link-local router goes.
        #expect(configuration.primaryIPv6?.router == "fe80::1")
        let wifi = configuration.interface("en0")
        #expect(wifi?.ipv4Router == "192.168.1.1")
        #expect(wifi?.ipv6Router == "fe80::1")
        #expect(configuration.interface("en7")?.ipv4Router == "10.0.0.1")
        // A tunnel's bare "fe80::" isn't a router to show.
        #expect(configuration.interface("utun4")?.ipv6Router == nil)
        #expect(configuration.interface("lo0")?.ipv4Router == nil)
    }

    @Test func dnsInUseIsTracedToTheServiceItCameFrom() {
        let dns = configuration.dns
        #expect(dns.servers == ["192.168.1.1", "2001:db8::1"])
        #expect(dns.searchDomains == ["home.arpa"])
        #expect(dns.source == .network)
        #expect(dns.sourceService == "Wi-Fi")
        #expect(dns.sourceInterface == "en0")
    }

    @Test func dnsTypedIntoThePrimaryServiceIsManual() {
        var store = NetworkFixture.store
        store["Setup:/Network/Service/\(NetworkFixture.wifiID)/DNS"] = ["ServerAddresses": ["1.1.1.1"]]
        store["State:/Network/Global/DNS"] = ["ServerAddresses": ["1.1.1.1"]]
        let dns = NetworkConfiguration.parseDNS(store, services: NetworkConfiguration.parseServices(store),
                                                primaryService: NetworkFixture.wifiID)
        #expect(dns.source == .manual)
        #expect(dns.sourceService == "Wi-Fi")
    }

    @Test func dnsFromAFullTunnelVPNSaysSo() {
        var store = NetworkFixture.store
        store["State:/Network/Global/DNS"] = ["ServerAddresses": ["10.8.0.1"], "DomainName": "corp.example"]
        store["State:/Network/Service/\(NetworkFixture.vpnID)/DNS"] = ["ServerAddresses": ["10.8.0.1"]]
        let dns = NetworkConfiguration.parseDNS(store, services: NetworkConfiguration.parseServices(store),
                                                primaryService: NetworkFixture.wifiID)
        #expect(dns.source == .vpn)
        #expect(dns.sourceInterface == "utun4")
        #expect(dns.sourceService == nil)
        // With no search list, short names are tried in the domain name.
        #expect(dns.effectiveSearchDomains == ["corp.example"])
    }

    @Test func noDNSHasNoSource() {
        let dns = NetworkConfiguration.parseDNS([:], services: [], primaryService: nil)
        #expect(dns == DNSStatus())
    }

    @Test func proxiesKeepHostsWhetherOrNotTheyAreOn() {
        let proxies = configuration.proxies
        #expect(proxies.server(.http) == .init(kind: .http, isEnabled: false, host: "proxy.corp.example", port: 8080))
        #expect(proxies.server(.https)?.isEnabled == true)
        #expect(proxies.server(.https)?.endpoint == "proxy.corp.example:8443")
        #expect(proxies.server(.socks) == .init(kind: .socks, isEnabled: false, host: nil, port: nil))
        #expect(proxies.autoConfigEnabled && proxies.autoConfigURL == "http://wpad.corp.example/proxy.pac")
        #expect(!proxies.autoDiscoveryEnabled)
        #expect(proxies.exceptions == ["*.local", "169.254/16"])
        #expect(proxies.excludesSimpleHostnames)
        #expect(proxies.isAnyEnabled)

        let none = ProxyStatus([:])
        #expect(!none.isAnyEnabled)
        #expect(none.servers.map(\.kind) == [.http, .https, .socks])
        #expect(ProxyStatus(["HTTPProxy": ""]).server(.http)?.host == nil)
    }

    @Test func splitDefaultRouteBeatsThePlainOne() {
        #expect(configuration.defaultRouteInterface(.ipv4) == "utun4")
        #expect(configuration.defaultRouteInterface(.ipv6) == "en0")
        #expect(configuration.tunnels.map(\.name) == ["utun0", "utun4"])

        var plain = configuration
        plain.defaultRoutes = NetworkFixture.routes.filter { $0.prefixLength == 0 }
        #expect(plain.defaultRouteInterface(.ipv4) == "en0")
        // Half a split default isn't a default route.
        plain.defaultRoutes = [NetworkFixture.routes[2]]
        #expect(plain.defaultRouteInterface(.ipv4) == nil)
        // Scoped defaults only serve traffic bound to their interface.
        plain.defaultRoutes = NetworkFixture.routes.filter(\.isScoped)
        #expect(plain.defaultRouteInterface(.ipv4) == nil && plain.defaultRouteInterface(.ipv6) == nil)
    }

    // MARK: - Routing table

    /// A `NET_RT_DUMP` record: the header, then the socket addresses its
    /// bits name, each padded to 4 bytes (an empty one still takes 4).
    private static func record(index: Int, flags: Int32, _ addresses: [(Int32, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        var bits: Int32 = 0
        for (bit, address) in addresses {
            bits |= bit
            let padded = address.isEmpty ? 4 : (address.count + 3) / 4 * 4
            body += address + Array(repeating: 0, count: padded - address.count)
        }
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        header.rtm_index = UInt16(index)
        header.rtm_flags = flags
        header.rtm_addrs = bits
        return withUnsafeBytes(of: header) { Array($0) } + body
    }

    private static func ipv4(_ bytes: [UInt8]) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0] + bytes + Array(repeating: 0, count: 12 - bytes.count)
    }

    private static func ipv6(_ bytes: [UInt8]) -> [UInt8] {
        [28, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + bytes + Array(repeating: 0, count: 20 - bytes.count)
    }

    /// The `AF_LINK` gateway of a route through an interface rather than a router.
    private static let link: [UInt8] = [20, UInt8(AF_LINK), 20, 0] + Array(repeating: 0, count: 16)
    /// Netmasks as the kernel cuts them short: /0 empty, /1 and /24 to their last byte.
    private static let half4: [UInt8] = [5, 0, 0, 0, 0x80]
    private static let half6: [UInt8] = [9, 0, 0, 0, 0, 0, 0, 0, 0x80]
    private static let slash24: [UInt8] = [7, 0, 0, 0, 255, 255, 255]

    @Test func routingTableYieldsDefaultsAndSplitHalves() {
        let up = RTF_UP | RTF_GATEWAY | RTF_STATIC
        var table: [UInt8] = []
        // en0's default, with the interface's own addresses after the netmask.
        table += Self.record(index: 4, flags: up, [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_GATEWAY, Self.ipv4([192, 168, 1, 1])),
                                                 (RTA_NETMASK, []), (RTA_IFP, Self.link), (RTA_IFA, Self.ipv4([192, 168, 1, 9]))])
        table += Self.record(index: 7, flags: up | RTF_IFSCOPE,
                             [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_GATEWAY, Self.ipv4([10, 0, 0, 1])), (RTA_NETMASK, [])])
        table += Self.record(index: 20, flags: RTF_UP | RTF_STATIC,
                             [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_GATEWAY, Self.link), (RTA_NETMASK, Self.half4)])
        table += Self.record(index: 20, flags: RTF_UP | RTF_STATIC,
                             [(RTA_DST, Self.ipv4([128, 0, 0, 0])), (RTA_GATEWAY, Self.link), (RTA_NETMASK, Self.half4)])
        // Not defaults: a host, a /24, one that's down, a reject route, and one on an interface that's gone.
        table += Self.record(index: 4, flags: RTF_UP | RTF_HOST, [(RTA_DST, Self.ipv4([192, 168, 1, 1])), (RTA_GATEWAY, Self.link)])
        table += Self.record(index: 4, flags: RTF_UP,
                             [(RTA_DST, Self.ipv4([192, 168, 1, 0])), (RTA_GATEWAY, Self.link), (RTA_NETMASK, Self.slash24)])
        table += Self.record(index: 4, flags: RTF_GATEWAY, [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_GATEWAY, Self.link), (RTA_NETMASK, [])])
        table += Self.record(index: 4, flags: up | RTF_REJECT, [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_NETMASK, [])])
        table += Self.record(index: 99, flags: up, [(RTA_DST, Self.ipv4([0, 0, 0, 0])), (RTA_NETMASK, [])])
        // IPv6: a router with the kernel's embedded scope (fe80:4::1), and half a split default.
        let router: [UInt8] = [0xFE, 0x80, 0, 4] + Array(repeating: 0, count: 11) + [1]
        table += Self.record(index: 4, flags: up, [(RTA_DST, Self.ipv6([])), (RTA_GATEWAY, Self.ipv6(router)), (RTA_NETMASK, [])])
        table += Self.record(index: 20, flags: RTF_UP, [(RTA_DST, Self.ipv6([0x80])), (RTA_GATEWAY, Self.link), (RTA_NETMASK, Self.half6)])
        // A cut-off record at the end is ignored.
        table += [92, 0, 5]

        let routes = DefaultRoute.parse(routingTable: table) { [4: "en0", 7: "en7", 20: "utun4"][$0] }
        #expect(routes == [
            DefaultRoute(family: .ipv4, interface: "en0", gateway: "192.168.1.1", destination: "0.0.0.0", prefixLength: 0, isScoped: false),
            DefaultRoute(family: .ipv4, interface: "en7", gateway: "10.0.0.1", destination: "0.0.0.0", prefixLength: 0, isScoped: true),
            DefaultRoute(family: .ipv4, interface: "utun4", gateway: nil, destination: "0.0.0.0", prefixLength: 1, isScoped: false),
            DefaultRoute(family: .ipv4, interface: "utun4", gateway: nil, destination: "128.0.0.0", prefixLength: 1, isScoped: false),
            DefaultRoute(family: .ipv6, interface: "en0", gateway: "fe80::1", destination: "::", prefixLength: 0, isScoped: false),
            DefaultRoute(family: .ipv6, interface: "utun4", gateway: nil, destination: "8000::", prefixLength: 1, isScoped: false),
        ])
        #expect(DefaultRoute.parse(routingTable: [], interfaceName: { _ in "en0" }).isEmpty)
    }

    @Test func prefixLengthsFromNetmasks() {
        #expect(InterfaceAddress.prefixLength(mask: [255, 255, 255, 0]) == 24)
        #expect(InterfaceAddress.prefixLength(mask: [255, 255, 254, 0]) == 23)
        #expect(InterfaceAddress.prefixLength(mask: [0, 0, 0, 0]) == 0)
        #expect(InterfaceAddress.prefixLength(mask: [255, 255, 255, 255]) == 32)
        #expect(InterfaceAddress.prefixLength(mask: Array(repeating: 255, count: 8) + Array(repeating: 0, count: 8)) == 64)
        // Not contiguous.
        #expect(InterfaceAddress.prefixLength(mask: [255, 0, 255, 0]) == nil)
        #expect(InterfaceAddress.prefixLength(mask: [0b1010_0000, 0, 0, 0]) == nil)
    }

    @Test func addressesKnowTheirScope() {
        #expect(NetworkFixture.address("169.254.10.2", 16).isLinkLocal)
        #expect(NetworkFixture.address("fe80::1", 64).isLinkLocal)
        #expect(NetworkFixture.address("FEBF::1", 64).isLinkLocal)
        #expect(!NetworkFixture.address("fec0::1", 64).isLinkLocal)
        #expect(NetworkFixture.address("fd12::1", 64).isUniqueLocal)
        #expect(!NetworkFixture.address("2001:db8::1", 64).isUniqueLocal)
        #expect(NetworkFixture.address("2001:db8::1", 64).withPrefix == "2001:db8::1/64")
        #expect(InterfaceAddress(family: .ipv4, address: "10.0.0.1", prefixLength: nil).withPrefix == "10.0.0.1")
    }

    @Test func mediaNamesTheNegotiatedEthernetLink() {
        let gigabit = NetworkMedia(current: 0x20, active: 0x20 | 16 | 0x0010_0000, status: 3)
        #expect(gigabit.summary == "1000baseT, full-duplex (autoselect)")
        #expect(gigabit.hasCarrier == true)
        // Set by hand, with flow control.
        let fixed = NetworkMedia(current: 0x20 | 22, active: 0x20 | 22 | 0x0010_0000 | 0x0040_0000, status: 3)
        #expect(fixed.summary == "2500baseT, full-duplex, flow control")
        // A type past 31 keeps its high bits apart: 32 is 2500baseSX.
        #expect(NetworkMedia(current: 0x20, active: 0x20 | 0x0001_0000, status: 3).activeType == "2500baseSX")
        #expect(NetworkMedia(current: 0x20, active: 0x20, status: 1).summary == "No carrier")
        // No word on the carrier, and nothing beyond autoselect to say.
        #expect(NetworkMedia(current: 0x20, active: 0x20, status: 0).hasCarrier == nil)
        #expect(NetworkMedia(current: 0x20, active: 0x20, status: 0).summary == nil)
        // Wi-Fi's media words aren't Ethernet's.
        #expect(NetworkMedia(current: 0x80, active: 0x80, status: 3).summary == nil)
    }

    @Test func flagsReadAsWords() {
        #expect(NetworkInterfaceDetails.flagNames(NetworkFixture.ethernetFlags) == ["up", "running", "broadcast", "multicast", "simplex"])
        #expect(NetworkInterfaceDetails.flagNames(NetworkFixture.tunnelFlags) == ["up", "running", "point-to-point", "multicast"])
        #expect(NetworkInterfaceDetails.flagNames(0).isEmpty)
        #expect(configuration.interface("utun4")?.isTunnel == true)
        #expect(configuration.interface("utun0")?.hasRoutableAddress == false)
        #expect(configuration.interface("en0")?.isUp == true)
    }

    @Test func wifiCodesReadAsWords() {
        #expect(WiFiDetails.standard(phyMode: 6) == "802.11ax (Wi-Fi 6)")
        #expect(WiFiDetails.standard(phyMode: 7) == "802.11be (Wi-Fi 7)")
        #expect(WiFiDetails.standard(phyMode: 0) == nil)
        #expect(WiFiDetails.band(3) == "6 GHz")
        #expect(WiFiDetails.channelWidth(4) == 160)
        #expect(WiFiDetails.security(11) == "WPA3 Personal")
        #expect(WiFiDetails.security(99) == nil)
        #expect(NetworkFixture.wifi.isAssociated)
    }
}
