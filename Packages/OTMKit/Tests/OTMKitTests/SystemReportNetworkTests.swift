import Foundation
@testable import OTMKit
import Testing

/// The Network and Network Configuration cards, their copied text, the saved
/// report's Markdown and JSON, and `otm netconfig`, from `NetworkFixture`.
struct SystemReportNetworkTests {
    private static let collected = Date(timeIntervalSince1970: 1_791_259_488)

    private static let info = SystemInfo(
        hardware: MacHardware(modelIdentifier: "Mac17,8", marketingName: nil, chip: "Apple M5 Pro", physicalMemory: 48 << 30,
                              pageSize: 16_384, kind: .laptop, serialNumber: "SERIAL123", hardwareUUID: "UUID-456"),
        topology: CPUTopology(brand: "Apple M5 Pro", architecture: "arm64", physicalCores: 18, logicalCores: 18, tiers: [], tierForCPU: [],
                              l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil, l3CacheBytes: nil,
                              isAppleSilicon: true),
        software: SoftwareInfo(productVersion: "27.2", build: "26B5101f", kernelRelease: nil, kernel: nil, bootTime: nil,
                               computerName: nil, localHostName: nil),
        gpus: [], disks: [], volumes: [], network: NetworkFixture.ports, battery: nil,
        networkConfiguration: NetworkFixture.configuration
    )

    /// Every identifier in the fixture: addresses, routers, DNS servers,
    /// search domains, proxy hosts, the PAC file's address, and the file
    /// servers, shares and account of the mounted volumes.
    private static let identifiers = [
        "192.168.1", "2001:db8", "fe80::1", "10.0.0", "10.8.0", "9.9.9.9", "home.arpa", "corp.example", "a4:83:e7", "00:e0:4c",
        "jamie", "export/builds",
    ]

    private func sections() -> [InfoSection] {
        SystemReport.sections(Self.info, displays: [], devices: nil, security: nil)
    }

    private func rows(_ kind: InfoSection.Kind) -> [InfoRow] {
        sections().first { $0.kind == kind }?.rows ?? []
    }

    /// The rows under the heading labelled `heading`, up to the next heading.
    private func group(_ heading: String, in rows: [InfoRow]) -> [InfoRow] {
        guard let start = rows.firstIndex(where: { $0.isHeading && $0.label == heading }) else { return [] }
        return Array(rows[(start + 1)...].prefix { !$0.isHeading })
    }

    private func value(_ label: String, in rows: [InfoRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    @Test func networkConfigurationCardFollowsTheNetworkCard() {
        let kinds = sections().map(\.kind)
        #expect(kinds == [.processor, .memory, .graphics, .displays, .storage, .controllers, .network, .networkConfiguration,
                          .networkVolumes, .firewall, .usb, .bluetooth, .audio, .software, .security])
        #expect(kinds.filter(\.isNetwork) == [.network, .networkConfiguration])
        #expect(sections().first { $0.kind == .networkConfiguration }?.title == "Network Configuration")
    }

    @Test func eachPortShowsPrefixesRouterLinkAndSettings() {
        let all = rows(.network)
        let headings = all.filter(\.isHeading)
        // utun0 has only a link-local address, so it isn't listed.
        #expect(headings.map(\.label) == ["Wi-Fi", "USB 10/100/1000 LAN", "utun4"])
        #expect(headings.map(\.interface) == ["en0", "en7", "utun4"])
        #expect(headings[0].headingNote == "en0, primary")
        #expect(headings[1].state == nil)

        let wifi = group("Wi-Fi", in: all)
        #expect(value("IPv4", in: wifi) == "192.168.1.9/24")
        // Link-local and deprecated addresses stay out; privacy ones get their own row.
        #expect(value("IPv6", in: wifi) == "2001:db8::5/64")
        #expect(value("Temporary IPv6", in: wifi) == "2001:db8::77/64")
        #expect(value("Router", in: wifi) == "192.168.1.1\nfe80::1")
        #expect(value("Channel", in: wifi) == "36 (5 GHz, 80 MHz wide)")
        #expect(value("Standard", in: wifi) == "802.11ax (Wi-Fi 6)")
        #expect(value("Signal", in: wifi) == "-52 dBm, noise -94 dBm")
        #expect(value("Security", in: wifi) == "WPA3 Personal")
        // The radio's rate, not the interface's stale figure.
        #expect(value("Link speed", in: wifi) == Format.bitsPerSecond(866_000_000 / 8) + " (transmit rate)")
        #expect(value("MTU", in: wifi) == "1500 bytes")
        #expect(value("Flags", in: wifi) == "up, running, broadcast, multicast, simplex")
        #expect(value("Configured", in: wifi) == "IPv4 by DHCP, IPv6 automatic")
        #expect(wifi.filter(\.isAddress).map(\.label) == ["IPv4", "IPv6", "Temporary IPv6", "Router"])
        #expect(wifi.first { $0.label == "Hardware address" }?.isSensitive == true)
        // Never the network's name.
        #expect(!wifi.contains { $0.label.contains("SSID") || $0.label == "Network name" })

        let wired = group("USB 10/100/1000 LAN", in: all)
        #expect(value("Media", in: wired) == "1000baseT, full-duplex (autoselect)")
        #expect(value("Link speed", in: wired) == Format.bitsPerSecond(1_000_000_000 / 8))
        #expect(value("Router", in: wired) == "10.0.0.1")
        #expect(value("Channel", in: wired) == nil)

        let tunnel = group("utun4", in: all)
        #expect(value("IPv4", in: tunnel) == "10.8.0.2/24")
        #expect(value("IPv6", in: tunnel) == nil)
        #expect(value("Router", in: tunnel) == "10.8.0.2")
        #expect(value("Flags", in: tunnel) == "up, running, point-to-point, multicast")
        // No System Settings service of its own.
        #expect(value("Configured", in: tunnel) == nil)
    }

    @Test func configurationCardSeparatesWhatsInUseFromWhatsConfigured() {
        let all = rows(.networkConfiguration)
        #expect(all.filter(\.isHeading).map(\.headingNote) == ["", "in System Settings"])
        let now = group("In use now", in: all)
        #expect(now.map(\.label) == [
            "Primary", "Default route", "VPN and tunnels", "DNS servers", "DNS from", "Search domains", "Proxies", "HTTP proxy",
            "HTTPS proxy", "Auto-config URL", "Bypassed for",
        ])
        #expect(value("Primary", in: now) == "Wi-Fi (en0)")
        // The VPN's split default beats Wi-Fi's for IPv4; IPv6 still goes out over Wi-Fi.
        #expect(value("Default route", in: now) == "IPv4: utun4 (VPN or tunnel)\nIPv6: en0")
        #expect(value("VPN and tunnels", in: now) == "utun4: carries the default route\nutun0: link-local only (system services)")
        #expect(value("DNS servers", in: now) == "192.168.1.1\n2001:db8::1")
        #expect(value("DNS from", in: now) == "Handed out by the network on Wi-Fi (en0)")
        #expect(value("Search domains", in: now) == "home.arpa")
        #expect(value("Proxies", in: now) == "HTTPS, auto-config (PAC) in use")
        #expect(value("HTTP proxy", in: now) == "proxy.corp.example:8080 (off)")
        #expect(value("HTTPS proxy", in: now) == "proxy.corp.example:8443")
        #expect(value("Auto-config URL", in: now) == "http://wpad.corp.example/proxy.pac")
        #expect(now.filter(\.isAddress).map(\.label) == [
            "DNS servers", "Search domains", "HTTP proxy", "HTTPS proxy", "Auto-config URL", "Bypassed for",
        ])

        let configured = group("Configured", in: all)
        #expect(configured.map(\.label).prefix(3) == ["Location", "Other location", "Service order"])
        #expect(value("Location", in: configured) == "Automatic (in use)")
        #expect(value("Other location", in: configured) == "Office: USB 10/100/1000 LAN, Wi-Fi (inactive)")
        #expect(value("Service order", in: configured) == """
        1. Wi-Fi (en0) · connected
        2. USB 10/100/1000 LAN (en7) · connected
        3. Thunderbolt Bridge (bridge0) · inactive
        """)
        #expect(value("USB 10/100/1000 LAN DNS", in: configured) == "9.9.9.9")
        #expect(value("USB 10/100/1000 LAN search", in: configured) == "corp.example")
        #expect(configured.filter(\.isAddress).count == 2)
    }

    @Test func quietConfigurationSaysNone() {
        var configuration = NetworkFixture.configuration
        configuration.defaultRoutes = []
        configuration.dns = DNSStatus()
        configuration.proxies = ProxyStatus()
        configuration.interfaces = configuration.interfaces.filter { !$0.isTunnel }
        configuration.primaryIPv4 = nil
        configuration.primaryIPv6 = nil
        let card = SystemReport.networkSections([], configuration).first { $0.kind == .networkConfiguration }?.rows ?? []
        for label in ["Primary", "Default route", "VPN and tunnels", "DNS servers", "Search domains"] {
            #expect(value(label, in: card) == "None", "\(label)")
        }
        #expect(value("Proxies", in: card) == "None in use")
        #expect(value("DNS from", in: card) == nil)
        #expect(!card.contains { $0.label.hasSuffix(" proxy") || $0.label == "Bypassed for" })
    }

    @Test func tunnelsAreSummedUpByWhatTheyDo() {
        func tunnel(_ name: String, up: Bool = true, _ addresses: [String]) -> NetworkInterfaceDetails {
            NetworkInterfaceDetails(name: name, flags: up ? NetworkFixture.tunnelFlags : 0, mtu: 1380, media: nil,
                                    addresses: addresses.map { NetworkFixture.address($0, 64) })
        }
        let tunnels = [tunnel("utun0", ["fe80::1"]), tunnel("utun1", ["fe80::2"]), tunnel("utun2", up: false, []),
                       tunnel("utun3", ["fd00::3"]), tunnel("utun4", ["10.8.0.2"])]
        #expect(SystemReport.tunnelSummary(tunnels, carryingDefault: ["utun4"]) == """
        utun2: down
        utun3: up, some routes only
        utun4: carries the default route
        utun0, utun1: link-local only (system services)
        """)
        #expect(SystemReport.tunnelSummary([], carryingDefault: []) == "None")
    }

    @Test func copiedSummaryKeepsAddressesButNotHardwareAddresses() {
        let text = SystemReport.text(Self.info, displays: [], devices: nil, security: nil, includeIdentifiers: false)
        #expect(text.contains("\nNetwork\n  Wi-Fi (en0, primary)\n    Status: Connected\n    IPv4: 192.168.1.9/24\n"))
        #expect(text.contains("    Router: 192.168.1.1\n            fe80::1\n"))
        #expect(text.contains("\nNetwork Configuration\n  In use now\n    Primary: Wi-Fi (en0)\n"))
        #expect(text.contains("  Configured (in System Settings)\n    Location: Automatic (in use)\n"
                + "    Other location: Office: USB 10/100/1000 LAN, Wi-Fi (inactive)\n    Service order: 1. Wi-Fi (en0) · connected\n"))
        // A share's server and where it's mounted are copied like addresses; the account isn't.
        #expect(text.contains("\nNetwork Volumes\n  Media (SMB)\n    Server: nas.home.arpa\n    Share: Media\n"))
        #expect(!text.contains("Account: "))
        #expect(!text.contains("a4:83:e7"))
        #expect(SystemReport.text(Self.info, displays: [], devices: nil, security: nil, includeIdentifiers: true).contains("a4:83:e7"))
    }

    @Test func markdownLeavesNetworkIdentifiersOutUnlessAsked() {
        let report = SystemReportDocument(info: Self.info, displays: [], devices: nil, devicesCollectedAt: nil, security: nil,
                                          collectedAt: Self.collected, generator: "otm test")
        let hidden = report.markdown(includeIdentifiers: false)
        for secret in Self.identifiers {
            #expect(!hidden.contains(secret), "\(secret) leaked")
        }
        #expect(hidden.contains("\n## Network Configuration\n\n- **In use now**\n  - Primary: Wi-Fi (en0)\n"))
        #expect(hidden.contains("  - Default route: IPv4: utun4 (VPN or tunnel), IPv6: en0\n"))
        #expect(hidden.contains("  - Proxies: HTTPS, auto-config (PAC) in use\n"))
        #expect(hidden.contains("- **Wi-Fi** (en0, primary)\n  - Status: Connected\n  - Channel: 36 (5 GHz, 80 MHz wide)\n"))
        // The shares keep their protocol and space, not where they're from.
        #expect(hidden.contains("\n## Network Volumes\n\n- **Media** (SMB)\n  - Mounted at: `/Volumes/Media`\n"
                + "  - Space: 1.25 TB free of 4 TB\n- **builds**"))
        #expect(hidden.contains("- **builds** (NFS, read-only)\n  - Space: Not reported by the server\n"
                + "  - Options: mounted on demand, hidden from Finder\n\nRead from this Mac's mount table"))

        let shown = report.markdown(includeIdentifiers: true)
        #expect(shown.contains("  - IPv4: `192.168.1.9/24`\n"))
        #expect(shown.contains("  - Router: `192.168.1.1`, `fe80::1`\n"))
        #expect(shown.contains("  - DNS servers: `192.168.1.1`, `2001:db8::1`\n"))
        #expect(shown.contains("  - HTTP proxy: `proxy.corp.example:8080 (off)`\n"))
        #expect(shown.contains("- **Media** (SMB)\n  - Server: `nas.home.arpa`\n  - Share: `Media`\n  - Mounted at: `/Volumes/Media`\n"))
        #expect(shown.contains("  - Account: `jamie`\n"))
    }

    @Test func jsonLeavesNetworkIdentifiersOutUnlessAsked() throws {
        let report = SystemReportDocument(info: Self.info, displays: [], devices: nil, devicesCollectedAt: nil, security: nil,
                                          collectedAt: Self.collected, generator: "otm test")
        let hiddenData = try report.json(includeIdentifiers: false)
        let hiddenText = try #require(String(data: hiddenData, encoding: .utf8))
        for secret in Self.identifiers {
            #expect(!hiddenText.contains(secret), "\(secret) leaked")
        }
        let hidden = try #require(JSONSerialization.jsonObject(with: hiddenData) as? [String: Any])
        let ports = try #require(hidden["network"] as? [[String: Any]])
        #expect(ports.map { $0["name"] as? String } == ["en0", "en7", "utun4"])
        #expect(ports.map { $0["isPrimary"] as? Bool } == [true, false, false])
        #expect(ports[0]["addressDetails"] is NSNull && ports[0]["ipv4Router"] is NSNull)
        #expect(ports[0]["mtu"] as? Int == 1500)
        #expect(ports[0]["flags"] as? [String] == ["up", "running", "broadcast", "multicast", "simplex"])
        #expect(ports[0]["service"] as? String == "Wi-Fi")
        let wifi = try #require(ports[0]["wifi"] as? [String: Any])
        #expect(wifi["channel"] as? Int == 36 && wifi["band"] as? String == "5 GHz" && wifi["rssiDBm"] as? Int == -52)
        #expect(ports[1]["media"] as? String == "1000baseT, full-duplex (autoselect)")
        #expect(ports[1]["wifi"] is NSNull)

        let setup = try #require(hidden["networkConfiguration"] as? [String: Any])
        #expect(setup["primaryInterface"] as? String == "en0")
        #expect(setup["primaryService"] as? String == "Wi-Fi")
        #expect(setup["router"] is NSNull)
        #expect(setup["defaultRouteInterface"] as? String == "utun4")
        #expect(setup["ipv6DefaultRouteInterface"] as? String == "en0")
        let routes = try #require(setup["defaultRoutes"] as? [[String: Any]])
        #expect(routes.count == 6 && routes.allSatisfy { $0["gateway"] is NSNull })
        let tunnels = try #require(setup["tunnels"] as? [[String: Any]])
        #expect(tunnels.map { $0["carriesDefaultRoute"] as? Bool } == [false, true])
        let dns = try #require(setup["dns"] as? [String: Any])
        #expect(dns["serverCount"] as? Int == 2 && dns["servers"] is NSNull)
        #expect(dns["searchDomainCount"] as? Int == 1 && dns["searchDomains"] is NSNull)
        #expect(dns["source"] as? String == "network")
        let proxies = try #require(setup["proxies"] as? [String: Any])
        let https = try #require(proxies["https"] as? [String: Any])
        #expect(https["isEnabled"] as? Bool == true && https["host"] is NSNull && https["port"] as? Int == 8443)
        #expect(proxies["autoConfigURL"] is NSNull && proxies["autoConfigEnabled"] as? Bool == true)
        let services = try #require(setup["services"] as? [[String: Any]])
        #expect(services.map { $0["name"] as? String } == ["Wi-Fi", "USB 10/100/1000 LAN", "Thunderbolt Bridge"])
        #expect(services[1]["manualDNSServers"] is NSNull && services[2]["isEnabled"] as? Bool == false)
        #expect(services[0]["ipv4ConfigMethod"] as? String == "DHCP")
        let locations = try #require(setup["locations"] as? [[String: Any]])
        #expect(locations.map { $0["name"] as? String } == ["Automatic", "Office"])
        #expect(locations.map { $0["isCurrent"] as? Bool } == [true, false])
        let office = try #require(locations[1]["services"] as? [[String: Any]])
        #expect(office.map { $0["isEnabled"] as? Bool } == [true, false])
        let volumes = try #require(setup["volumes"] as? [[String: Any]])
        #expect(volumes.map { $0["kind"] as? String } == ["smb", "nfs"])
        #expect(volumes.map { $0["name"] as? String } == ["Media", "builds"])
        #expect(volumes[0]["server"] is NSNull && volumes[0]["share"] is NSNull && volumes[0]["account"] is NSNull)
        // A mount point in a home folder names the user.
        #expect(volumes[0]["mountPoint"] as? String == "/Volumes/Media" && volumes[1]["mountPoint"] is NSNull)
        #expect(volumes[0]["availableBytes"] as? Int == 1_250_000_000_000 && volumes[1]["totalBytes"] is NSNull)
        #expect(volumes[1]["isReadOnly"] as? Bool == true && volumes[1]["isAutomounted"] as? Bool == true)
        #expect(volumes[1]["isHiddenFromFinder"] as? Bool == true)

        let shown = try #require(JSONSerialization.jsonObject(with: report.json(includeIdentifiers: true)) as? [String: Any])
        let shownPort = try #require((shown["network"] as? [[String: Any]])?.first)
        let addresses = try #require(shownPort["addressDetails"] as? [[String: Any]])
        #expect(addresses.contains { $0["address"] as? String == "192.168.1.9" && $0["prefixLength"] as? Int == 24 })
        #expect(addresses.contains { $0["address"] as? String == "2001:db8::66" && $0["isDeprecated"] as? Bool == true })
        #expect(shownPort["ipv4Router"] as? String == "192.168.1.1")
        let shownSetup = try #require(shown["networkConfiguration"] as? [String: Any])
        #expect((shownSetup["dns"] as? [String: Any])?["servers"] as? [String] == ["192.168.1.1", "2001:db8::1"])
        #expect(((shownSetup["proxies"] as? [String: Any])?["http"] as? [String: Any])?["host"] as? String == "proxy.corp.example")
        let shownVolumes = try #require(shownSetup["volumes"] as? [[String: Any]])
        #expect(shownVolumes[0]["server"] as? String == "nas.home.arpa" && shownVolumes[0]["account"] as? String == "jamie")
        #expect(shownVolumes[1]["share"] as? String == "/export/builds")
        #expect(shownVolumes[1]["mountPoint"] as? String == "/Users/jamie/builds")
    }

    @Test func netconfigPrintsTheTwoCards() throws {
        let text = SystemReport.networkText(NetworkFixture.ports, configuration: NetworkFixture.configuration, includeIdentifiers: false)
        #expect(text.hasPrefix("Network\n  Wi-Fi (en0, primary)\n    Status: Connected\n    IPv4: 192.168.1.9/24\n"))
        #expect(text.contains("\n\nNetwork Configuration\n  In use now\n"))
        #expect(text.contains("\n\nNetwork Volumes\n  Media (SMB)\n    Server: nas.home.arpa\n"))
        // The firewall's card only when it was read.
        #expect(!text.contains("Firewall"))
        #expect(!text.contains("a4:83:e7"))
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        let all = SystemReport.networkText(NetworkFixture.ports, configuration: NetworkFixture.configuration, includeIdentifiers: true)
        #expect(all.contains("    Hardware address: a4:83:e7:0b:12:9c\n"))

        let data = try SystemReportDocument.networkJSON(NetworkFixture.ports, configuration: NetworkFixture.configuration,
                                                        includeIdentifiers: false, collectedAt: Self.collected)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == [
            "format", "schemaVersion", "collectedAt", "includesIdentifiers", "network", "networkConfiguration", "firewall",
        ])
        // Not read here: there, but null.
        #expect(json["firewall"] is NSNull)
        #expect(json["format"] as? String == SystemReportDocument.format)
        let text2 = try #require(String(data: data, encoding: .utf8))
        #expect(!text2.contains("192.168.1"))
    }

    @Test func withoutTheConfigurationTheNetworkCardIsAsBefore() {
        let cards = SystemReport.networkSections(NetworkFixture.ports, nil)
        #expect(cards.map(\.kind) == [.network])
        let wifi = group("Wi-Fi", in: cards[0].rows)
        #expect(value("IPv4", in: wifi) == "192.168.1.9")
        #expect(value("IPv6", in: wifi) == "2001:db8::5\n2001:db8::77\n2001:db8::66")
        #expect(value("Link speed", in: wifi) == Format.bitsPerSecond(53_950_000 / 8))
        #expect(cards[0].rows.first { $0.isHeading }?.state == nil)
        #expect(!cards[0].rows.contains { ["MTU", "Flags", "Router", "Configured"].contains($0.label) })
    }
}
