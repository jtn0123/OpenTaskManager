import Foundation

/// Who a launchd job runs for, which follows from the folder its property list is in.
public enum LaunchItemScope: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    /// `~/Library/LaunchAgents`: starts in your login session only.
    case userAgent
    /// `/Library/LaunchAgents` and `/System/Library/LaunchAgents`: starts in every user's session.
    case systemAgent
    /// `/Library/LaunchDaemons` and `/System/Library/LaunchDaemons`: starts at boot, outside any session.
    case daemon

    public var isAgent: Bool { self != .daemon }

    public var title: String {
        switch self {
        case .userAgent: "User agent"
        case .systemAgent: "System agent"
        case .daemon: "Daemon"
        }
    }

    /// For a narrow column: "Agent" or "Daemon".
    public var shortTitle: String { isAgent ? "Agent" : "Daemon" }

    private var rank: Int {
        switch self {
        case .userAgent: 0
        case .systemAgent: 1
        case .daemon: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Whether Apple ships the item. Third-party items sort first.
public enum LaunchItemPublisher: String, Sendable, Codable, Hashable, Comparable {
    case thirdParty
    case apple

    public var title: String { self == .apple ? "Apple" : "Third party" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs == .thirdParty && rhs == .apple
    }
}

/// What a job is doing now, from launchd and the property list.
public enum LaunchItemState: Sendable, Hashable, Comparable {
    case running(pid: Int32)
    /// Loaded into launchd and waiting for its trigger.
    case loaded
    /// Turned off with `launchctl disable` or the plist's `Disabled` key.
    case disabled
    case notLoaded

    public var title: String {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .disabled: "Disabled"
        case .notLoaded: "Not loaded"
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// A folder launchd loads property lists from.
public struct LaunchDirectory: Sendable, Hashable {
    public let path: String
    public let scope: LaunchItemScope

    public init(path: String, scope: LaunchItemScope) {
        self.path = path
        self.scope = scope
    }

    public static func standard(home: String = NSHomeDirectory()) -> [LaunchDirectory] {
        [
            LaunchDirectory(path: home + "/Library/LaunchAgents", scope: .userAgent),
            LaunchDirectory(path: "/Library/LaunchAgents", scope: .systemAgent),
            LaunchDirectory(path: "/Library/LaunchDaemons", scope: .daemon),
            LaunchDirectory(path: "/System/Library/LaunchAgents", scope: .systemAgent),
            LaunchDirectory(path: "/System/Library/LaunchDaemons", scope: .daemon),
        ]
    }
}

/// A launchd property list and, once correlated, what launchd says about its job.
public struct LaunchItem: Sendable, Codable, Hashable, Identifiable {
    public var id: String { plistPath }
    /// The `Label` key, or the file name when the plist has none or can't be read.
    public let label: String
    /// A readable name made from the label, such as "Microsoft Update Agent".
    public let name: String
    public let plistPath: String
    public let modified: Date?
    public let scope: LaunchItemScope
    public let publisher: LaunchItemPublisher
    /// What launchd runs: `Program`, or else the first of `ProgramArguments`.
    public let program: String?
    /// `ProgramArguments`, starting with the program's own name.
    public let arguments: [String]
    public let triggers: LaunchTriggers
    /// The plist's own `Disabled` key.
    public let disabledInPlist: Bool
    /// The plist has no `Label`, so launchd won't load it.
    public let isMissingLabel: Bool
    /// The file couldn't be read or isn't a property list dictionary.
    public let isUnreadable: Bool
    /// Set when launchd has loaded the job.
    public var job: LaunchJobStatus?
    /// `launchctl enable` (false) or `disable` (true), which wins over `disabledInPlist`.
    public var disabledOverride: Bool?

    public var isDisabled: Bool { disabledOverride ?? disabledInPlist }

    public var pid: Int32? { job?.pid }

    public var state: LaunchItemState {
        if let pid = job?.pid { return .running(pid: pid) }
        if isDisabled { return .disabled }
        return job == nil ? .notLoaded : .loaded
    }

    /// What the state means for a process, which "Loaded" alone doesn't say:
    /// its PID while it runs, "Not running" while launchd holds it until its
    /// trigger, and for a disabled item whether launchd still holds it.
    public var stateDetail: String? {
        switch state {
        // Interpolated as a string, so the PID isn't grouped like a quantity.
        case let .running(pid): "PID \(pid)"
        case .loaded: "Not running"
        case .disabled: job == nil ? "Not loaded" : "Not running"
        case .notLoaded: nil
        }
    }

    /// The state in plain words for the details: "Running · PID 501",
    /// "Loaded · Not running", "Not loaded".
    public var statusSummary: String {
        [state.title, stateDetail].compactMap(\.self).joined(separator: " · ")
    }

    /// Starts by itself whenever it's enabled: at login for agents, at boot for daemons.
    public var startsAutomatically: Bool {
        !isMissingLabel && !isUnreadable && !isDisabled && triggers.startsWhenLoaded
    }

    public var timing: LaunchTiming { isUnreadable ? .unknown : triggers.timing }

    /// Short form for a table column: "At login", "Every hour", "On demand".
    public var launchSummary: String {
        isUnreadable ? LaunchTiming.unknown.title(for: scope) : triggers.summary(for: scope)
    }

    /// The outermost app bundle around the program, for its icon.
    public var appBundlePath: String? { LaunchItems.appBundlePath(forProgram: program) }
}

/// Reads launchd property lists and works out what each one does.
public enum LaunchItems {
    /// Reads every property list in `directories` and asks launchctl which
    /// jobs are loaded, running or disabled. This reads hundreds of files and
    /// runs launchctl three times, so call it off the main actor.
    public static func scan(directories: [LaunchDirectory] = LaunchDirectory.standard(), uid: uid_t = getuid()) -> [LaunchItem] {
        withCurrentStatus(directories.flatMap { read($0) }, uid: uid)
    }

    /// The same items with launchd asked again which jobs are loaded, running
    /// or disabled. It runs launchctl three times and reads no property list,
    /// so the Startup page can follow restarts with it; call it off the main actor.
    public static func withCurrentStatus(_ items: [LaunchItem], uid: uid_t = getuid()) -> [LaunchItem] {
        let system = Launchctl.systemDomain()
        return correlate(items, userJobs: Launchctl.userJobs(), systemJobs: system.jobs,
                         userOverrides: Launchctl.userOverrides(uid: uid), systemOverrides: system.overrides)
    }

    static func read(_ directory: LaunchDirectory) -> [LaunchItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.sorted().map { name in
            let url = URL(fileURLWithPath: directory.path).appendingPathComponent(name)
            let modified = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return item(plist: try? Data(contentsOf: url), path: url.path, scope: directory.scope, modified: modified)
        }
    }

    /// Classifies one property list. `data` is nil when the file couldn't be read.
    public static func item(plist data: Data?, path: String, scope: LaunchItemScope, modified: Date? = nil) -> LaunchItem {
        let fileLabel = (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
        guard let data, let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return LaunchItem(label: fileLabel, name: displayName(forLabel: fileLabel), plistPath: path, modified: modified,
                              scope: scope, publisher: publisher(plistPath: path, label: fileLabel), program: nil,
                              arguments: [], triggers: LaunchTriggers(), disabledInPlist: false,
                              isMissingLabel: false, isUnreadable: true)
        }
        let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = (plist["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? arguments.first
        let shownLabel = label ?? fileLabel
        return LaunchItem(label: shownLabel, name: displayName(forLabel: shownLabel), plistPath: path, modified: modified,
                          scope: scope, publisher: publisher(plistPath: path, label: shownLabel), program: program,
                          arguments: arguments, triggers: LaunchTriggers(plist: plist),
                          disabledInPlist: plist["Disabled"] as? Bool ?? false,
                          isMissingLabel: label == nil, isUnreadable: false)
    }

    /// Apple's own items live under /System or carry an Apple label.
    public static func publisher(plistPath: String, label: String) -> LaunchItemPublisher {
        plistPath.hasPrefix("/System/") || label.hasPrefix("com.apple.") ? .apple : .thirdParty
    }

    /// Attaches launchd's state to each item. Agents load into your session
    /// and daemons into the system domain, so each looks in its own tables.
    public static func correlate(_ items: [LaunchItem],
                                 userJobs: [String: LaunchJobStatus],
                                 systemJobs: [String: LaunchJobStatus],
                                 userOverrides: [String: Bool],
                                 systemOverrides: [String: Bool]) -> [LaunchItem] {
        items.map { item in
            // launchd never loads a plist without a label, whatever its file is called.
            guard !item.isMissingLabel else { return item }
            var item = item
            let daemon = item.scope == .daemon
            item.job = (daemon ? systemJobs : userJobs)[item.label]
            item.disabledOverride = (daemon ? systemOverrides : userOverrides)[item.label]
            return item
        }
    }

    /// The outermost `.app` on the path, so a helper inside OneDrive.app gets OneDrive's icon.
    public static func appBundlePath(forProgram program: String?) -> String? {
        guard let program, program.hasPrefix("/") else { return nil }
        var path = ""
        for component in program.split(separator: "/") {
            path += "/" + component
            if component.hasSuffix(".app") { return path }
        }
        return nil
    }

    // MARK: Names

    /// Turns a reverse-DNS label into a readable name. The domain goes, and so
    /// does the vendor when it's Apple or already part of the name:
    /// "com.microsoft.update.agent" becomes "Microsoft Update Agent",
    /// "com.apple.Safari.SafeBrowsing" becomes "Safari Safe Browsing" and
    /// "homebrew.mxcl.grafana" becomes "Grafana".
    public static func displayName(forLabel label: String) -> String {
        var parts = label.split(separator: ".").map(String.init)
        if parts.count > 2, parts[0] == "homebrew", parts[1] == "mxcl" {
            parts.removeFirst(2)
        } else if parts.count > 1, topLevelDomains.contains(parts[0].lowercased()) {
            parts.removeFirst()
            if parts.count > 1 {
                let vendor = parts[0].lowercased()
                let rest = parts.dropFirst().joined().lowercased()
                if vendor == "apple" || rest.contains(vendor) { parts.removeFirst() }
            }
        }
        let words = parts.flatMap(words(in:))
        return words.isEmpty ? label : words.joined(separator: " ")
    }

    /// Splits "OneDriveUpdater" or "mac-helper" into capitalised words. Short
    /// lowercase prefixes stay attached, so "iCloud" stays whole, and an
    /// acronym keeps its capitals: "XPCService" becomes "XPC Service".
    static func words(in text: String) -> [String] {
        var words: [String] = []
        for chunk in text.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }) {
            let characters = Array(chunk)
            var current = ""
            for (index, character) in characters.enumerated() {
                if index > 0, character.isUppercase {
                    let previous = characters[index - 1]
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    let lowerToUpper = previous.isLowercase && current.count > 1
                    let acronymEnd = previous.isUppercase && next?.isLowercase == true
                    if lowerToUpper || acronymEnd {
                        words.append(current)
                        current = ""
                    }
                }
                current.append(character)
            }
            words.append(current)
        }
        return words.filter { !$0.isEmpty }.map { word in
            // "iCloud" and "eGPU" are already cased the way their makers want.
            word.dropFirst().first?.isUppercase == true ? word : word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "de", "uk", "fr", "jp", "ch", "nl", "se", "no", "fi", "dk", "at", "be",
        "it", "es", "ru", "cn", "us", "ca", "au", "nz", "edu", "gov", "me", "app", "dev", "ai", "tv", "cc", "eu",
        "info", "biz", "xyz", "sh", "is", "pl", "cz", "br", "in", "kr", "tw", "hk",
    ]
}
