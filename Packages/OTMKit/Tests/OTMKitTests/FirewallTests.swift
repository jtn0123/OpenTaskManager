import Foundation
@testable import OTMKit
import Testing

/// Reading the application firewall's settings from `system_profiler` and
/// `socketfilterfw` output captured without administrator rights, and the
/// Firewall card built from them.
struct FirewallTests {
    /// A virtual machine on macOS 27 with the firewall off: app rules macOS
    /// added for itself, and the two sharing services turned on.
    private static let offProfiler = """
    {
      "SPFirewallDataType" : [
        {
          "_name" : "spfirewall_settings",
          "spfirewall_applications" : {
            "com.apple.CoreDevice.remotepairingdeviced" : "spfirewall_allow_all",
            "com.apple.cupsd" : "spfirewall_allow_all",
            "com.apple.dt.xcode_select.tool-shim-public" : "spfirewall_allow_all",
            "com.apple.remoted" : "spfirewall_allow_all",
            "com.apple.ruby" : "spfirewall_allow_all",
            "com.apple.sharingd" : "spfirewall_allow_all",
            "com.apple.smbd" : "spfirewall_allow_all",
            "com.apple.sshd-keygen-wrapper" : "spfirewall_allow_all"
          },
          "spfirewall_globalstate" : "spfirewall_globalstate_allow_all",
          "spfirewall_loggingenabled" : "No",
          "spfirewall_services" : {
            "Remote Login - SSH" : "spfirewall_allow_all",
            "Screen Sharing" : "spfirewall_allow_all"
          },
          "spfirewall_stealthenabled" : "No"
        }
      ]
    }
    """

    /// A laptop with the firewall on: no service rules, so no services key,
    /// one app blocked and one limited to the local network.
    private static let onProfiler = """
    {
      "SPFirewallDataType" : [
        {
          "_name" : "spfirewall_settings",
          "spfirewall_applications" : {
            "EQHXZ8M8AV.com.google.Chrome" : "spfirewall_allow_all",
            "com.apple.cupsd" : "spfirewall_allow_all",
            "bun" : "spfirewall_block_all",
            "ABCDE12345.com.example.Media" : "spfirewall_allow_local",
            "com.apple.sharingd" : "spfirewall_allow_all"
          },
          "spfirewall_globalstate" : "spfirewall_globalstate_limit_connections",
          "spfirewall_loggingenabled" : "Yes",
          "spfirewall_stealthenabled" : "Yes"
        }
      ]
    }
    """

    /// `socketfilterfw --getglobalstate --getblockall --getstealthmode --getallowsigned`, firewall on.
    private static let onTool = """
    Firewall is enabled. (State = 1)
    Firewall has block all state set to disabled.
    Firewall stealth mode is off
    Automatically allow built-in signed software ENABLED.
    Automatically allow downloaded signed software DISABLED.
    """

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Parsing

    @Test func profilerReadsAFirewallThatIsOff() throws {
        let status = try #require(FirewallStatus.parseProfiler(Self.data(Self.offProfiler)))
        #expect(status.mode == .off)
        #expect(status.stealthMode == false && status.logging == false)
        #expect(status.apps?.count == 8)
        #expect(status.apps?.allSatisfy { $0.policy == .allow } == true)
        #expect(status.services == [.init(name: "Remote Login - SSH", policy: .allow), .init(name: "Screen Sharing", policy: .allow)])
        #expect(status.sources == [.systemProfiler])
        // Only socketfilterfw says how signed software is treated.
        #expect(status.allowsBuiltInSigned == nil && status.allowsDownloadedSigned == nil)
    }

    @Test func profilerSortsRulesAndReadsEachPolicy() throws {
        let status = try #require(FirewallStatus.parseProfiler(Self.data(Self.onProfiler)))
        #expect(status.mode == .on)
        #expect(status.stealthMode == true && status.logging == true)
        #expect(status.apps?.map(\.name) == [
            "ABCDE12345.com.example.Media", "bun", "com.apple.cupsd", "com.apple.sharingd", "EQHXZ8M8AV.com.google.Chrome",
        ])
        #expect(status.apps?.map(\.policy) == [.allowLocal, .block, .allow, .allow, .allow])
        // A missing rules key means none, not unknown.
        #expect(status.services == [])
    }

    @Test func profilerReadsBlockAllAndRejectsOtherReports() {
        let blockAll = Self.offProfiler.replacingOccurrences(of: "spfirewall_globalstate_allow_all", with: "spfirewall_globalstate_block_all")
        #expect(FirewallStatus.parseProfiler(Self.data(blockAll))?.mode == .blockAll)
        let unknown = Self.offProfiler.replacingOccurrences(of: "spfirewall_globalstate_allow_all", with: "spfirewall_globalstate_new")
        #expect(FirewallStatus.parseProfiler(Self.data(unknown))?.mode == nil)
        // A rules value that isn't a table is unread, not empty.
        let odd = Self.onProfiler.replacingOccurrences(of: "\"spfirewall_loggingenabled\"", with: "\"spfirewall_services\" : \"none\",\n"
            + "\"spfirewall_loggingenabled\"")
        #expect(FirewallStatus.parseProfiler(Self.data(odd))?.services == nil)
        #expect(FirewallStatus.parseProfiler(Self.data("{ \"SPFirewallDataType\" : [ ] }")) == nil)
        #expect(FirewallStatus.parseProfiler(Self.data("{ \"SPUSBDataType\" : [ ] }")) == nil)
        #expect(FirewallStatus.parseProfiler(Self.data("not json")) == nil)
    }

    @Test func socketFilterReadsEachAnswer() throws {
        let on = try #require(FirewallStatus.parseSocketFilter(Self.onTool))
        #expect(on.mode == .on)
        #expect(on.stealthMode == false)
        #expect(on.allowsBuiltInSigned == true && on.allowsDownloadedSigned == false)
        #expect(on.logging == nil && on.apps == nil)

        let blocking = try #require(FirewallStatus.parseSocketFilter("""
        Firewall is enabled. (State = 2)
        Firewall has block all state set to enabled.
        Firewall stealth mode is on
        """))
        #expect(blocking.mode == .blockAll && blocking.stealthMode == true)

        let off = try #require(FirewallStatus.parseSocketFilter("Firewall is disabled. (State = 0)\n"))
        #expect(off.mode == .off && off.stealthMode == nil)
        // Block all on its own doesn't say whether the firewall is on.
        #expect(FirewallStatus.parseSocketFilter("Firewall has block all state set to enabled.")?.mode == nil)
        #expect(FirewallStatus.parseSocketFilter("") == nil)
        #expect(FirewallStatus.parseSocketFilter("Must be root to change settings.\n") == nil)
    }

    @Test func bothToolsCombine() {
        let both = FirewallStatus(profilerJSON: Self.data(Self.offProfiler), socketFilterOutput: Self.onTool)
        // The profiler's answer stands; the tool adds what only it knows.
        #expect(both.mode == .off)
        #expect(both.allowsBuiltInSigned == true && both.allowsDownloadedSigned == false)
        #expect(both.sources == [.systemProfiler, .socketFilter])
        #expect(both.missing.isEmpty)

        let toolOnly = FirewallStatus(profilerJSON: nil, socketFilterOutput: Self.onTool)
        #expect(toolOnly.mode == .on && toolOnly.sources == [.socketFilter])
        #expect(toolOnly.missing == ["logging", "app rules", "service rules"])

        let profilerOnly = FirewallStatus(profilerJSON: Self.data(Self.onProfiler), socketFilterOutput: "garbage")
        #expect(profilerOnly.sources == [.systemProfiler])
        #expect(profilerOnly.missing == ["the signed-software settings"])

        let neither = FirewallStatus(profilerJSON: Self.data("{}"), socketFilterOutput: nil)
        #expect(neither.sources.isEmpty && neither.mode == nil)
        #expect(neither.missing.count == 6)
    }

    // MARK: - The card

    private func value(_ label: String, in rows: [InfoRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    @Test func cardSaysCheckingThenWhatItCouldntRead() {
        #expect(SystemReport.firewallRows(nil).map(\.value) == ["Checking…"])
        #expect(SystemReport.firewallSection(nil).note == nil)

        let unread = SystemReport.firewallRows(FirewallStatus(profilerJSON: nil, socketFilterOutput: nil))
        #expect(unread.map(\.label) == ["Application firewall", "Not read"])
        #expect(unread[0].value == "Couldn't read" && unread[0].status == .unknown)
        #expect(unread[1].value == "Packet filter (pf) rules, which need administrator rights")
    }

    @Test func cardGivesPolicyNotReachability() {
        let status = FirewallStatus(profilerJSON: Self.data(Self.onProfiler), socketFilterOutput: Self.onTool)
        let rows = SystemReport.firewallRows(status)
        #expect(rows.map(\.label) == [
            "Application firewall", "Stealth mode", "Logging", "Signed software", "App rules", "Blocked apps", "Local network only",
            "Read from", "Not read",
        ])
        #expect(rows[0].value == "On: incoming connections are filtered by app" && rows[0].status == .good)
        #expect(value("Stealth mode", in: rows) == "On: doesn't answer pings or probes of closed ports")
        #expect(value("Signed software", in: rows) == "Built-in signed apps allowed automatically, downloaded ones need a rule")
        #expect(value("App rules", in: rows) == "3 allowed, 1 blocked, 1 local network only")
        #expect(value("Blocked apps", in: rows) == "bun")
        #expect(value("Local network only", in: rows) == "ABCDE12345.com.example.Media")
        #expect(value("Read from", in: rows) == "system_profiler and socketfilterfw, without administrator rights")

        let section = SystemReport.firewallSection(status)
        #expect(section.kind == .firewall && section.title == "Firewall")
        #expect(section.note?.contains("not a test of what can reach this Mac") == true)
        // Nothing on the card claims what can or can't get in.
        for row in rows {
            #expect(!row.value.lowercased().contains("reachable") && !row.value.lowercased().contains("protected"), "\(row.label)")
        }
    }

    @Test func offFirewallIsPlainAndItsRulesWait() {
        let rows = SystemReport.firewallRows(FirewallStatus(profilerJSON: Self.data(Self.offProfiler), socketFilterOutput: nil))
        #expect(rows[0].value == "Off: incoming connections aren't filtered")
        // Off is a setting, not a fault: no warning.
        #expect(rows[0].status == nil)
        #expect(value("App rules", in: rows) == "8 allowed (not applied while it's off)")
        #expect(value("Services", in: rows) == "Remote Login - SSH: allowed\nScreen Sharing: allowed")
        #expect(value("Read from", in: rows) == "system_profiler, without administrator rights")
        let missing = rows.first { $0.label == "Not returned" }
        #expect(missing?.value == "the signed-software settings" && missing?.status == .unknown)
    }

    @Test func blockAllAndUnknownModesAndCounts() {
        var status = FirewallStatus(mode: .blockAll, apps: [], services: [], sources: [.socketFilter])
        var rows = SystemReport.firewallRows(status)
        #expect(rows[0].value == "On, blocking incoming connections but those macOS needs" && rows[0].status == .good)
        #expect(value("App rules", in: rows) == "None")
        #expect(value("Services", in: rows) == nil)
        status.mode = nil
        rows = SystemReport.firewallRows(status)
        #expect(rows[0].value == "Not reported" && rows[0].status == .unknown)
        #expect(SystemReport.ruleCounts([.init(name: "a", policy: .block), .init(name: "b", policy: .block)]) == "2 blocked")
    }

    // MARK: - Text and JSON

    @Test func netconfigAddsTheFirewallCard() throws {
        let status = FirewallStatus(profilerJSON: Self.data(Self.offProfiler), socketFilterOutput: Self.onTool)
        let text = SystemReport.networkText([], configuration: nil, firewall: status, includeIdentifiers: false)
        #expect(text.contains("\n\nFirewall\n  Application firewall: Off: incoming connections aren't filtered\n"))
        #expect(text.contains("  Not read: Packet filter (pf) rules, which need administrator rights\n  These are the firewall's settings"))

        let data = try SystemReportDocument.networkJSON([], configuration: nil, firewall: status, includeIdentifiers: false,
                                                        collectedAt: Date(timeIntervalSince1970: 0))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let firewall = try #require(json["firewall"] as? [String: Any])
        #expect(firewall["mode"] as? String == "off")
        #expect(firewall["stealthMode"] as? Bool == false && firewall["logging"] as? Bool == false)
        #expect(firewall["allowsBuiltInSignedSoftware"] as? Bool == true)
        #expect(firewall["allowsDownloadedSignedSoftware"] as? Bool == false)
        #expect((firewall["appRules"] as? [[String: Any]])?.count == 8)
        #expect((firewall["serviceRules"] as? [[String: Any]])?.first?["policy"] as? String == "allow")
        #expect(firewall["sources"] as? [String] == ["systemProfiler", "socketFilter"])
        #expect(firewall["notRead"] as? [String] == ["packetFilterRules"])

        let unread = try SystemReportDocument.networkJSON([], configuration: nil, firewall: FirewallStatus(profilerJSON: nil,
                                                          socketFilterOutput: nil), includeIdentifiers: false)
        let unreadFirewall = try #require((JSONSerialization.jsonObject(with: unread) as? [String: Any])?["firewall"] as? [String: Any])
        #expect(unreadFirewall["mode"] is NSNull && unreadFirewall["appRules"] is NSNull)
        #expect(unreadFirewall["sources"] as? [String] == [])
    }
}
