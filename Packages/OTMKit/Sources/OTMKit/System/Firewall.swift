import Foundation

/// The application firewall's settings, as far as a process without
/// administrator rights can read them: whether it's on, stealth mode,
/// logging, the signed-software rules, and the apps and services it
/// allows or blocks. This is policy, not exposure: whether anything can
/// reach this Mac also depends on what's listening, the packet filter (pf),
/// whose rules need administrator rights, and the network in between.
/// Each fact is nil when no tool returned it.
public struct FirewallStatus: Sendable, Hashable {
    public enum Mode: String, Sendable, Codable {
        /// Lets every incoming connection through.
        case off
        /// Lets in only the apps and services it allows.
        case on
        /// Blocks every incoming connection but those macOS needs to work.
        case blockAll
    }

    /// What a rule does with an app's or service's incoming connections.
    public enum Policy: String, Sendable, Codable {
        case allow, block, allowLocal

        public var title: String {
            switch self {
            case .allow: "allowed"
            case .block: "blocked"
            case .allowLocal: "local network only"
            }
        }
    }

    public struct Rule: Sendable, Hashable {
        /// A bundle identifier (often after a team ID: "ABCDE12345.com.example.app"),
        /// a tool's name ("cupsd"), or a service's ("Screen Sharing").
        public let name: String
        public let policy: Policy

        public init(name: String, policy: Policy) {
            self.name = name
            self.policy = policy
        }
    }

    /// The tools read, neither of which needs administrator rights.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// `system_profiler SPFirewallDataType`: mode, stealth mode, logging,
        /// app and service rules.
        case systemProfiler
        /// `socketfilterfw --getglobalstate --getblockall --getstealthmode
        /// --getallowsigned`: on or off, block all, stealth mode and the
        /// signed-software settings.
        case socketFilter

        public var title: String {
            switch self {
            case .systemProfiler: "system_profiler"
            case .socketFilter: "socketfilterfw"
            }
        }
    }

    public var mode: Mode?
    public var stealthMode: Bool?
    public var logging: Bool?
    /// Software that comes with macOS gets incoming connections without a rule.
    public var allowsBuiltInSigned: Bool?
    /// Downloaded software with a valid signature does too.
    public var allowsDownloadedSigned: Bool?
    /// The apps and tools with a rule, by name.
    public var apps: [Rule]?
    /// Sharing services with a rule (Screen Sharing, Remote Login).
    public var services: [Rule]?
    /// The tools that answered, in the order above.
    public var sources: [Source]

    public init(mode: Mode? = nil, stealthMode: Bool? = nil, logging: Bool? = nil, allowsBuiltInSigned: Bool? = nil,
                allowsDownloadedSigned: Bool? = nil, apps: [Rule]? = nil, services: [Rule]? = nil, sources: [Source] = []) {
        self.mode = mode
        self.stealthMode = stealthMode
        self.logging = logging
        self.allowsBuiltInSigned = allowsBuiltInSigned
        self.allowsDownloadedSigned = allowsDownloadedSigned
        self.apps = apps
        self.services = services
        self.sources = sources
    }

    /// Combines what each tool printed (nil for a tool that failed). The
    /// profiler's facts come first; `socketfilterfw` fills in the rest and
    /// alone has the signed-software settings.
    public init(profilerJSON: Data?, socketFilterOutput: String?) {
        self.init()
        if let profiler = profilerJSON.flatMap(Self.parseProfiler) {
            self = profiler
        }
        if let text = socketFilterOutput, let tool = Self.parseSocketFilter(text) {
            mode = mode ?? tool.mode
            stealthMode = stealthMode ?? tool.stealthMode
            allowsBuiltInSigned = tool.allowsBuiltInSigned
            allowsDownloadedSigned = tool.allowsDownloadedSigned
            sources.append(.socketFilter)
        }
    }

    /// The facts no tool returned, in the page's words.
    public var missing: [String] {
        let facts: [(String, Bool)] = [
            ("whether it's on", mode == nil), ("stealth mode", stealthMode == nil), ("logging", logging == nil),
            ("the signed-software settings", allowsBuiltInSigned == nil && allowsDownloadedSigned == nil),
            ("app rules", apps == nil), ("service rules", services == nil),
        ]
        return facts.filter(\.1).map(\.0)
    }

    // MARK: - Parsing

    /// `system_profiler -json SPFirewallDataType`; nil when it holds no
    /// firewall settings. The rules are sorted by name.
    public static func parseProfiler(_ data: Data) -> FirewallStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPFirewallDataType"] as? [[String: Any]],
              let settings = entries.first(where: { $0["_name"] as? String == "spfirewall_settings" }) ?? entries.first
        else { return nil }
        let mode: Mode? = switch settings["spfirewall_globalstate"] as? String {
        case "spfirewall_globalstate_allow_all": .off
        case "spfirewall_globalstate_limit_connections": .on
        case "spfirewall_globalstate_block_all": .blockAll
        default: nil
        }
        func yesNo(_ key: String) -> Bool? {
            switch (settings[key] as? String)?.lowercased() {
            case "yes", "on", "enabled": true
            case "no", "off", "disabled": false
            default: nil
            }
        }
        func rules(_ key: String) -> [Rule]? {
            // A firewall with no rules leaves the key out: read, and none.
            guard let table = settings[key] as? [String: Any] else { return settings[key] == nil ? [] : nil }
            return table.compactMap { name, value -> Rule? in
                let policy: Policy? = switch value as? String {
                case "spfirewall_allow_all": .allow
                case "spfirewall_block_all": .block
                case "spfirewall_allow_local": .allowLocal
                default: nil
                }
                return policy.map { Rule(name: name, policy: $0) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return FirewallStatus(mode: mode, stealthMode: yesNo("spfirewall_stealthenabled"), logging: yesNo("spfirewall_loggingenabled"),
                              apps: rules("spfirewall_applications"), services: rules("spfirewall_services"),
                              sources: [.systemProfiler])
    }

    /// `socketfilterfw`'s answers, one per line ("Firewall is enabled.
    /// (State = 1)", "Firewall has block all state set to disabled.",
    /// "Firewall stealth mode is off", "Automatically allow built-in signed
    /// software ENABLED."); nil when none of them is there.
    public static func parseSocketFilter(_ text: String) -> FirewallStatus? {
        var status = FirewallStatus()
        var enabled: Bool?
        var blocksAll: Bool?
        var found = false
        for line in text.split(whereSeparator: \.isNewline).map({ $0.lowercased() }) {
            let on = line.contains("enabled") || line.hasSuffix(" on") || line.contains(" on.")
            let off = line.contains("disabled") || line.hasSuffix(" off") || line.contains(" off.")
            guard on != off else { continue }
            if line.contains("block all") {
                blocksAll = on
            } else if line.contains("stealth mode") {
                status.stealthMode = on
            } else if line.contains("built-in signed") {
                status.allowsBuiltInSigned = on
            } else if line.contains("downloaded signed") {
                status.allowsDownloadedSigned = on
            } else if line.hasPrefix("firewall is") {
                enabled = on
            } else {
                continue
            }
            found = true
        }
        guard found else { return nil }
        status.mode = enabled.map { enabled in enabled ? (blocksAll == true ? .blockAll : .on) : .off }
        return status
    }
}

/// Reads the firewall's settings with the two tools that work without
/// administrator rights. About a quarter of a second; never per sample.
public enum FirewallReader {
    static let socketFilter = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    public static func read(timeout: TimeInterval = 10) async -> FirewallStatus {
        async let profiler = CommandRunner.cancellableExecute(
            "/usr/sbin/system_profiler", ["-json", "-timeout", String(Int(timeout / 2)), "SPFirewallDataType"], capture: .output,
            timeout: timeout
        )
        async let tool = CommandRunner.cancellableExecute(
            socketFilter, ["--getglobalstate", "--getblockall", "--getstealthmode", "--getallowsigned"], capture: .output,
            timeout: timeout
        )
        let profilerResult = await profiler
        let toolResult = await tool
        return FirewallStatus(
            profilerJSON: profilerResult.flatMap { $0.status == 0 ? Data($0.text.utf8) : nil },
            socketFilterOutput: toolResult.flatMap { $0.status == 0 ? $0.text : nil }
        )
    }
}
