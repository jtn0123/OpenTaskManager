import Foundation

/// The System page's Firewall card: the application firewall's settings as
/// read without administrator rights, which tools they came from and what
/// couldn't be read. Settings are policy: the card never says whether
/// anything can reach this Mac.
extension SystemReport {
    /// What the card's note says under every reading.
    static let firewallNote = "These are the firewall's settings, not a test of what can reach this Mac: that also depends on "
        + "which apps are listening, the packet filter and the network in between."

    /// The card, with "Checking…" while `status` is nil.
    static func firewallSection(_ status: FirewallStatus?) -> InfoSection {
        InfoSection(kind: .firewall, title: "Firewall", rows: firewallRows(status), note: status == nil ? nil : firewallNote)
    }

    static func firewallRows(_ status: FirewallStatus?) -> [InfoRow] {
        guard let status else { return [InfoRow("Application firewall", "Checking…")] }
        let notRead = InfoRow("Not read", "Packet filter (pf) rules, which need administrator rights")
        guard !status.sources.isEmpty else {
            return [InfoRow("Application firewall", "Couldn't read", status: .unknown), notRead]
        }
        var rows = [modeRow(status.mode)]
        if let stealth = status.stealthMode {
            rows.append(InfoRow("Stealth mode", stealth ? "On: doesn't answer pings or probes of closed ports" : "Off"))
        }
        if let logging = status.logging { rows.append(InfoRow("Logging", logging ? "On" : "Off")) }
        if let signed = signedSoftware(status) { rows.append(InfoRow("Signed software", signed)) }
        let inForce = status.mode != .off
        if let apps = status.apps {
            rows.append(InfoRow("App rules", ruleCounts(apps) + (inForce || apps.isEmpty ? "" : " (not applied while it's off)")))
            for policy in [FirewallStatus.Policy.block, .allowLocal] {
                let names = apps.filter { $0.policy == policy }.map(\.name)
                if !names.isEmpty {
                    rows.append(InfoRow(policy == .block ? "Blocked apps" : "Local network only", names.joined(separator: "\n"),
                                        isCode: true))
                }
            }
        }
        if let services = status.services, !services.isEmpty {
            rows.append(InfoRow("Services", services.map { "\($0.name): \($0.policy.title)" }.joined(separator: "\n")))
        }
        let tools = status.sources.map(\.title)
        rows.append(InfoRow("Read from", tools.joined(separator: " and ") + ", without administrator rights"))
        let missing = status.missing
        if !missing.isEmpty {
            rows.append(InfoRow("Not returned", missing.joined(separator: ", "), status: .unknown))
        }
        rows.append(notRead)
        return rows
    }

    private static func modeRow(_ mode: FirewallStatus.Mode?) -> InfoRow {
        switch mode {
        case .off: InfoRow("Application firewall", "Off: incoming connections aren't filtered")
        case .on: InfoRow("Application firewall", "On: incoming connections are filtered by app", status: .good)
        case .blockAll: InfoRow("Application firewall", "On, blocking incoming connections but those macOS needs", status: .good)
        case nil: InfoRow("Application firewall", "Not reported", status: .unknown)
        }
    }

    /// Whether signed software gets incoming connections without a rule.
    private static func signedSoftware(_ status: FirewallStatus) -> String? {
        switch (status.allowsBuiltInSigned, status.allowsDownloadedSigned) {
        case (true, true): "Built-in and downloaded signed apps allowed automatically"
        case (true, false): "Built-in signed apps allowed automatically, downloaded ones need a rule"
        case (false, true): "Downloaded signed apps allowed automatically, built-in ones need a rule"
        case (false, false): "Every app needs a rule"
        case (true, nil): "Built-in signed apps allowed automatically"
        case (false, nil): "Built-in signed apps need a rule"
        case (nil, true): "Downloaded signed apps allowed automatically"
        case (nil, false): "Downloaded signed apps need a rule"
        case (nil, nil): nil
        }
    }

    /// "39 allowed", "37 allowed, 2 blocked", "None".
    static func ruleCounts(_ rules: [FirewallStatus.Rule]) -> String {
        guard !rules.isEmpty else { return "None" }
        let counts = [FirewallStatus.Policy.allow, .block, .allowLocal].compactMap { policy -> String? in
            let count = rules.filter { $0.policy == policy }.count
            return count == 0 ? nil : "\(count) \(policy.title)"
        }
        return counts.joined(separator: ", ")
    }
}
