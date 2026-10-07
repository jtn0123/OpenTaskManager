import Foundation

/// The System page's Network card (each port's addresses, router, link and
/// how System Settings sets it up), its Network Configuration card (what
/// the whole Mac uses now: the primary service, default routes, tunnels, DNS
/// and proxies, then the locations and services as configured) and its
/// Network Volumes card (shares mounted from servers). Addresses, routers,
/// DNS servers, search domains, proxy hosts, file servers and shares are
/// `isAddress` rows: shown and copied like the page's IP addresses, left
/// out of a saved report unless identifiers are included.
extension SystemReport {
    /// The Network card, and the configuration and volumes cards when the
    /// configuration was read.
    static func networkSections(_ ports: [NetworkPortInfo], _ configuration: NetworkConfiguration?) -> [InfoSection] {
        var sections = [InfoSection(kind: .network, title: "Network", rows: networkRows(ports, configuration))]
        if let configuration {
            sections.append(InfoSection(kind: .networkConfiguration, title: "Network Configuration",
                                        rows: configurationRows(configuration)))
            sections.append(InfoSection(
                kind: .networkVolumes, title: "Network Volumes", rows: volumeRows(configuration.volumes),
                note: configuration.volumes.isEmpty ? nil
                    : "Read from this Mac's mount table, so listing a share never contacts its server. "
                    + "Free space is the server's last answer."
            ))
        }
        return sections
    }

    // MARK: - Ports

    private static func networkRows(_ ports: [NetworkPortInfo], _ configuration: NetworkConfiguration?) -> [InfoRow] {
        let ports = ports.filter(\.isWorthListing)
        guard !ports.isEmpty else { return [InfoRow("Network", "No active connections")] }
        let primary = configuration.flatMap { $0.primaryIPv4?.interface ?? $0.primaryIPv6?.interface }
        var rows: [InfoRow] = []
        for port in ports {
            let details = configuration?.interface(port.name)
            // Ports without a friendly name ("bridge100") would otherwise repeat it.
            rows.append(InfoRow(port.displayName, port.displayName == port.name ? "" : port.name, isHeading: true,
                                state: port.name == primary ? "primary" : nil, interface: port.name))
            let connected = port.isUp && !port.addresses.isEmpty
            rows.append(InfoRow("Status", connected ? "Connected" : "Not connected", status: connected ? .good : nil))
            rows += details.map(addressRows) ?? plainAddressRows(port)
            rows += linkRows(port, details: details, connected: connected)
            if let service = configuration?.service(on: port.name) {
                let setUp = service.isEnabled ? service.methodSummary ?? "No addresses set up" : "Inactive in System Settings"
                rows.append(InfoRow("Configured", setUp))
            }
            if let address = port.hardwareAddress {
                rows.append(InfoRow("Hardware address", address, isSensitive: true, isCode: true))
            }
        }
        return rows
    }

    /// The addresses alone, where the configuration wasn't read.
    private static func plainAddressRows(_ port: NetworkPortInfo) -> [InfoRow] {
        let ipv4 = port.addresses.filter { !$0.contains(":") }
        let ipv6 = port.addresses.filter { $0.contains(":") && !$0.lowercased().hasPrefix("fe80") }
        var rows: [InfoRow] = []
        if !ipv4.isEmpty { rows.append(InfoRow("IPv4", ipv4.joined(separator: "\n"), isCode: true, isAddress: true)) }
        if !ipv6.isEmpty { rows.append(InfoRow("IPv6", ipv6.joined(separator: "\n"), isCode: true, isAddress: true)) }
        return rows
    }

    /// Addresses with their prefixes, and the routers the port's service
    /// has now. IPv6 stays tidy: the link-local address every port has is
    /// left out, and so are deprecated ones, which only finish connections
    /// already open; rotating privacy addresses get their own row.
    private static func addressRows(_ details: NetworkInterfaceDetails) -> [InfoRow] {
        let ipv4 = details.addresses.filter { $0.family == .ipv4 }
        let ipv6 = details.addresses.filter { $0.family == .ipv6 && !$0.isLinkLocal && !$0.isDeprecated }
        let lists = [
            ("IPv4", ipv4.map(\.withPrefix)),
            ("IPv6", ipv6.filter { !$0.isTemporary }.map(\.withPrefix)),
            ("Temporary IPv6", ipv6.filter(\.isTemporary).map(\.withPrefix)),
            ("Router", [details.ipv4Router, details.ipv6Router].compactMap { $0 }),
        ]
        return lists.filter { !$0.1.isEmpty }.map { InfoRow($0.0, $0.1.joined(separator: "\n"), isCode: true, isAddress: true) }
    }

    /// The radio or the cable, the speed, MTU and flags.
    private static func linkRows(_ port: NetworkPortInfo, details: NetworkInterfaceDetails?, connected: Bool) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let wifi = details?.wifi, wifi.isAssociated { rows += wifiRows(wifi) }
        if let media = details?.media, media.isEthernet, let summary = media.summary { rows.append(InfoRow("Media", summary)) }
        if let wifi = details?.wifi, wifi.isAssociated, let rate = wifi.transmitRateMbps {
            // The radio's current rate: a Wi-Fi interface's own figure lags behind it.
            rows.append(InfoRow("Link speed", Format.bitsPerSecond(rate * 1_000_000 / 8) + " (transmit rate)"))
        } else if let speed = port.linkSpeed, connected {
            rows.append(InfoRow("Link speed", Format.bitsPerSecond(Double(speed) / 8)))
        }
        if let details {
            if let mtu = details.mtu { rows.append(InfoRow("MTU", "\(mtu) bytes")) }
            let flags = details.flagNames
            if !flags.isEmpty { rows.append(InfoRow("Flags", flags.joined(separator: ", "))) }
        }
        return rows
    }

    /// What CoreWLAN gives without Location Services: never the network's name.
    private static func wifiRows(_ wifi: WiFiDetails) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let channel = wifi.channel {
            let notes = [wifi.band, wifi.channelWidthMHz.map { "\($0) MHz wide" }].compactMap { $0 }
            rows.append(InfoRow("Channel", "\(channel)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")))
        }
        if let standard = wifi.standard { rows.append(InfoRow("Standard", standard)) }
        // CoreWLAN gives 0 where it has no reading.
        if let rssi = wifi.rssi, rssi != 0 {
            let noise = wifi.noise.flatMap { $0 == 0 ? nil : ", noise \($0) dBm" } ?? ""
            rows.append(InfoRow("Signal", "\(rssi) dBm\(noise)"))
        }
        if let security = wifi.security { rows.append(InfoRow("Security", security)) }
        return rows
    }

    // MARK: - Configuration

    private static func configurationRows(_ configuration: NetworkConfiguration) -> [InfoRow] {
        var rows = [InfoRow("In use now", "", isHeading: true)]
        rows += routeRows(configuration)
        rows += dnsRows(configuration.dns)
        rows += proxyRows(configuration.proxies)
        rows.append(InfoRow("Configured", "in System Settings", isHeading: true))
        rows += locationRows(configuration.locations)
        rows += serviceRows(configuration.services)
        return rows
    }

    /// The location in use, then each other one with its services. The one
    /// in use has its services in the service order below.
    static func locationRows(_ locations: [NetworkLocation]) -> [InfoRow] {
        guard !locations.isEmpty else { return [InfoRow("Location", "Couldn't read", status: .unknown)] }
        let current = locations.first(where: \.isCurrent)
        var rows = [InfoRow("Location", current.map { $0.name + (locations.count == 1 ? " (the only one)" : " (in use)") } ?? "None chosen")]
        let others = locations.filter { !$0.isCurrent }
        if !others.isEmpty {
            let lines = others.map { location in
                let services = location.services.map { $0.name + ($0.isEnabled ? "" : " (inactive)") }
                return location.name + ": " + (services.isEmpty ? "no services" : services.joined(separator: ", "))
            }
            rows.append(InfoRow(others.count == 1 ? "Other location" : "Other locations", lines.joined(separator: "\n")))
        }
        return rows
    }

    // MARK: - Volumes

    /// Each mounted share: protocol, server, share, where it's mounted and
    /// its space. The server and share are addresses; the account identifies
    /// the user, so it's hidden like a serial number.
    static func volumeRows(_ volumes: [NetworkVolume]) -> [InfoRow] {
        guard !volumes.isEmpty else { return [InfoRow("Shares", "None mounted")] }
        var rows: [InfoRow] = []
        for volume in volumes {
            rows.append(InfoRow(volume.name, volume.kind.title, isHeading: true, state: volume.isReadOnly ? "read-only" : nil))
            rows.append(InfoRow("Server", volume.server ?? "Not recorded", isCode: volume.server != nil, isAddress: volume.server != nil))
            if let share = volume.share { rows.append(InfoRow("Share", share, isCode: true, isAddress: true)) }
            rows.append(InfoRow("Mounted at", volume.mountPoint, isCode: true, isAddress: volume.mountPoint.hasPrefix("/Users/")))
            if let total = volume.totalBytes, let free = volume.availableBytes {
                rows.append(InfoRow("Space", "\(SystemFacts.decimalBytes(free)) free of \(SystemFacts.decimalBytes(total))"))
            } else {
                rows.append(InfoRow("Space", "Not reported by the server"))
            }
            if let account = volume.account { rows.append(InfoRow("Account", account, isSensitive: true, isCode: true)) }
            let options = [volume.isAutomounted ? "mounted on demand" : nil, volume.isHidden ? "hidden from Finder" : nil].compactMap { $0 }
            if !options.isEmpty { rows.append(InfoRow("Options", options.joined(separator: ", "))) }
        }
        return rows
    }

    /// "Wi-Fi (en0)", or the bare name for a port with no service.
    private static func portName(_ interface: String, _ configuration: NetworkConfiguration) -> String {
        configuration.service(on: interface).map { "\($0.name) (\(interface))" } ?? interface
    }

    /// The primary service, which interface the default routes use, and the tunnels.
    private static func routeRows(_ configuration: NetworkConfiguration) -> [InfoRow] {
        var rows: [InfoRow] = []
        let primaries = [("IPv4", configuration.primaryIPv4), ("IPv6", configuration.primaryIPv6)].compactMap { label, primary in
            primary.map { (label, portName($0.interface, configuration)) }
        }
        rows.append(InfoRow("Primary", lines(primaries, none: "None")))

        let ipv4 = configuration.defaultRouteInterface(.ipv4)
        let ipv6 = configuration.defaultRouteInterface(.ipv6)
        let routes = [("IPv4", ipv4), ("IPv6", ipv6)].compactMap { label, name in
            name.map { (label, $0 + (configuration.interface($0)?.isTunnel == true ? " (VPN or tunnel)" : "")) }
        }
        rows.append(InfoRow("Default route", lines(routes, none: "None")))
        rows.append(InfoRow("VPN and tunnels", tunnelSummary(configuration.tunnels, carryingDefault: Set([ipv4, ipv6].compactMap { $0 }))))
        return rows
    }

    /// One value when both families agree ("Wi-Fi (en0)"), a line each otherwise.
    private static func lines(_ items: [(String, String)], none: String) -> String {
        if items.isEmpty { return none }
        if Set(items.map(\.1)).count == 1 { return items[0].1 }
        return items.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// A line for each tunnel worth a word (one carrying the default route,
    /// one with a routable address), then the link-local-only ones macOS
    /// keeps for its own services together.
    static func tunnelSummary(_ tunnels: [NetworkInterfaceDetails], carryingDefault: Set<String>) -> String {
        guard !tunnels.isEmpty else { return "None" }
        var lines: [String] = []
        var idle: [String] = []
        for tunnel in tunnels {
            if carryingDefault.contains(tunnel.name) {
                lines.append("\(tunnel.name): carries the default route")
            } else if !tunnel.isUp {
                lines.append("\(tunnel.name): down")
            } else if tunnel.hasRoutableAddress {
                lines.append("\(tunnel.name): up, some routes only")
            } else {
                idle.append(tunnel.name)
            }
        }
        if !idle.isEmpty { lines.append(idle.joined(separator: ", ") + ": link-local only (system services)") }
        return lines.joined(separator: "\n")
    }

    private static func dnsRows(_ dns: DNSStatus) -> [InfoRow] {
        var rows = [dns.servers.isEmpty
            ? InfoRow("DNS servers", "None")
            : InfoRow("DNS servers", dns.servers.joined(separator: "\n"), isCode: true, isAddress: true)]
        if let source = dns.source {
            let place = [dns.sourceService, dns.sourceInterface.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            let service = place.isEmpty ? "the primary service" : place
            let from = switch source {
            case .manual: "Set by hand for \(service)"
            case .network: "Handed out by the network on \(service)"
            case .vpn: "Set by the VPN on \(dns.sourceInterface ?? "a tunnel")"
            }
            rows.append(InfoRow("DNS from", from))
        }
        let domains = dns.effectiveSearchDomains
        rows.append(domains.isEmpty
            ? InfoRow("Search domains", "None")
            : InfoRow("Search domains", domains.joined(separator: "\n"), isCode: true, isAddress: true))
        return rows
    }

    /// What's on, then each proxy host with whether it's on: a host stays
    /// set up in System Settings after its switch is turned off.
    private static func proxyRows(_ proxies: ProxyStatus) -> [InfoRow] {
        var on = proxies.servers.filter(\.isEnabled).map(\.kind.title)
        if proxies.autoConfigEnabled { on.append("auto-config (PAC)") }
        if proxies.autoDiscoveryEnabled { on.append("auto-discovery (WPAD)") }
        var rows = [InfoRow("Proxies", on.isEmpty ? "None in use" : on.joined(separator: ", ") + " in use")]
        for server in proxies.servers {
            guard let endpoint = server.endpoint else { continue }
            rows.append(InfoRow("\(server.kind.title) proxy", endpoint + (server.isEnabled ? "" : " (off)"), isCode: true, isAddress: true))
        }
        if let url = proxies.autoConfigURL {
            rows.append(InfoRow("Auto-config URL", url + (proxies.autoConfigEnabled ? "" : " (off)"), isCode: true, isAddress: true))
        }
        if !on.isEmpty, !proxies.exceptions.isEmpty {
            rows.append(InfoRow("Bypassed for", proxies.exceptions.joined(separator: "\n"), isCode: true, isAddress: true))
        }
        return rows
    }

    /// System Settings' services in order, then DNS typed in for any of them.
    private static func serviceRows(_ services: [NetworkServiceInfo]) -> [InfoRow] {
        guard !services.isEmpty else { return [InfoRow("Service order", "None")] }
        let order = services.enumerated().map { index, service in
            let state = !service.isEnabled ? "inactive" : service.isActive ? "connected" : "not connected"
            return "\(index + 1). \(service.name)\(service.interface.map { " (\($0))" } ?? "") · \(state)"
        }
        var rows = [InfoRow("Service order", order.joined(separator: "\n"))]
        for service in services {
            if !service.manualDNSServers.isEmpty {
                rows.append(InfoRow("\(service.name) DNS", service.manualDNSServers.joined(separator: "\n"), isCode: true, isAddress: true))
            }
            if !service.manualSearchDomains.isEmpty {
                rows.append(InfoRow("\(service.name) search", service.manualSearchDomains.joined(separator: "\n"), isCode: true,
                                    isAddress: true))
            }
        }
        return rows
    }
}
