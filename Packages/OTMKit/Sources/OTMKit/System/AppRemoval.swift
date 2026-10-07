import Darwin
import Foundation

/// Finds what an app leaves in your Library and works out what moving it to
/// the Trash involves. Nothing here deletes anything: the app moves the
/// chosen items with `NSWorkspace.recycle`, so they can come back out of the
/// Trash.
///
/// A file's name doesn't prove which app owns it, so every item carries the
/// evidence that links it. Only exact bundle-ID matches start selected; name,
/// team and app-group matches, and anything another installed copy of the
/// app also uses, are shown unselected as uncertain.
public enum AppRemoval {
    // MARK: Who it's for

    /// Why removal isn't offered for an app, or nil when it is: never for
    /// macOS's own apps, Apple's apps or OpenTaskManager itself.
    public static func refusal(for app: InstalledApp, ownBundleIdentifier: String?, ownBundlePath: String?) -> String? {
        let paths = [app.path, app.resolvedPath].map(InstalledApps.normalized)
        if paths.contains(where: { $0.hasPrefix("/System/") }) { return "It's part of macOS." }
        if app.kind == .apple || app.bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true {
            return "It's one of Apple's apps."
        }
        if let own = ownBundleIdentifier, app.bundleIdentifier?.caseInsensitiveCompare(own) == .orderedSame {
            return "It's OpenTaskManager."
        }
        if let own = ownBundlePath.map(InstalledApps.normalized), paths.contains(own) { return "It's OpenTaskManager." }
        return nil
    }

    // MARK: Finding what goes with it

    /// The review for `app`: its bundle, the launch agents that run from it,
    /// and what's named after it in your Library, plus what was found but
    /// needs an administrator. `otherApps` (every other installed app)
    /// keeps another app's files out and marks files a second copy of this
    /// app shares. `launchItems` is a fresh `LaunchItems.scan()`. Reads a
    /// dozen folders, so call it off the main actor.
    public static func plan(for app: InstalledApp, otherApps: [InstalledApp], launchItems: [LaunchItem],
                            home: String = NSHomeDirectory(), systemLibrary: String = "/Library",
                            canRemove: (String) -> Bool = canRemove) -> AppRemovalPlan {
        // Paths stay as the scan found them; comparisons go through `normalized`.
        let bundle = app.resolvedPath
        let others = otherApps.filter { InstalledApps.normalized($0.resolvedPath) != InstalledApps.normalized(bundle) }
        let rules = MatchRules(app: app, others: others)
        var items: [LeftoverItem] = []
        var protected: [ProtectedLeftover] = []
        var blocker: String?

        // The bundle, and the link it was found through if there is one.
        if canRemove(bundle) {
            items.append(LeftoverItem(path: bundle, location: .app, evidence: .theApp, confidence: .required))
        } else {
            blocker = "Your account can't move it: \(ownership(of: bundle, fallback: "its folder is protected"))."
            protected.append(ProtectedLeftover(path: bundle, reason: "The app itself: \(ownership(of: bundle, fallback: "protected"))",
                                               evidence: .theApp))
        }
        let found = app.path
        if InstalledApps.normalized(found) != InstalledApps.normalized(bundle), isSymbolicLink(found) {
            if canRemove(found) {
                items.append(LeftoverItem(path: found, location: .app, evidence: .linkToApp, confidence: .required))
            } else {
                protected.append(ProtectedLeftover(path: found, reason: "Link in a folder your account can't change", evidence: .linkToApp))
            }
        }

        let agents = launchAgents(for: app, in: launchItems, home: home, canRemove: canRemove)
        items += agents.items
        protected += agents.protected

        let library = home + "/Library"
        for location in LeftoverLocation.allCases where location != .app && location != .launchAgents {
            for folder in location.folders {
                for match in matches(in: library + "/" + folder, location: location, rules: rules) {
                    let path = library + "/" + folder + "/" + match.name
                    guard canRemove(path) else {
                        protected.append(ProtectedLeftover(path: path, reason: ownership(of: path, fallback: "Your account can't move it"),
                                                           evidence: match.evidence))
                        continue
                    }
                    let caveat = rules.caveat(for: match.evidence)
                    items.append(LeftoverItem(path: path, location: location, evidence: match.evidence,
                                              confidence: caveat == nil ? match.confidence : .uncertain, caveat: caveat))
                }
            }
        }

        protected += systemLeftovers(for: app, rules: rules, systemLibrary: systemLibrary)
        protected += systemExtensions(inBundleAt: bundle)
        return AppRemovalPlan(app: app, items: ordered(items), protected: dedupe(protected), blocker: blocker)
    }

    /// A name in a folder that belongs to the app, and why.
    struct NameMatch {
        let name: String
        let evidence: LeftoverEvidence
        let confidence: LeftoverConfidence
    }

    /// The names in `folder` that belong to the app. Hidden files are skipped.
    static func matches(in folder: String, location: LeftoverLocation, rules: MatchRules) -> [NameMatch] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), let match = rules.match(name, in: location, byHost: folder.hasSuffix("/ByHost")) else {
                return nil
            }
            return NameMatch(name: name, evidence: match.evidence, confidence: match.confidence)
        }
    }

    /// The app's launch agents in your LaunchAgents folder, and the rest of
    /// its launchd jobs, which need an administrator.
    static func launchAgents(for app: InstalledApp, in launchItems: [LaunchItem], home: String,
                             canRemove: (String) -> Bool) -> (items: [LeftoverItem], protected: [ProtectedLeftover]) {
        let identifier = app.bundleIdentifier?.lowercased()
        let bundles = Set([app.path, app.resolvedPath].map(InstalledApps.normalized))
        let userFolder = InstalledApps.normalized(home + "/Library/LaunchAgents") + "/"
        var items: [LeftoverItem] = []
        var protected: [ProtectedLeftover] = []
        for item in InstalledApps.launchItems(for: app, in: launchItems) where !item.plistPath.hasPrefix("/System/") {
            let program = ([item.program].compactMap { $0 } + item.arguments).first { $0.hasPrefix("/") && isInside($0, bundles: bundles) }
            let evidence: LeftoverEvidence = program.map { .runsFromApp(program: $0) } ?? .launchLabel(item.label)
            let path = item.plistPath
            guard item.scope == .userAgent, InstalledApps.normalized(path).hasPrefix(userFolder), canRemove(path) else {
                let reason = switch item.scope {
                case .daemon: "Launch daemon: runs as root for the whole Mac"
                case .systemAgent: "Launch agent for every account, in /Library"
                case .userAgent: "Your account can't move it"
                }
                protected.append(ProtectedLeftover(path: path, reason: reason, evidence: evidence))
                continue
            }
            let confidence: LeftoverConfidence = if program != nil {
                .required
            } else if item.label.lowercased() == identifier {
                .exact
            } else {
                .uncertain
            }
            items.append(LeftoverItem(path: path, location: .launchAgents, evidence: evidence, confidence: confidence, launchItem: item))
        }
        return (items, protected)
    }

    /// What the app has in /Library and its privileged helpers. Shared by
    /// every account and usually owned by root, so it's listed, never moved.
    static func systemLeftovers(for app: InstalledApp, rules: MatchRules, systemLibrary: String) -> [ProtectedLeftover] {
        var found: [ProtectedLeftover] = []
        let locations: [(LeftoverLocation, String)] = [
            (.applicationSupport, "Application Support"), (.caches, "Caches"), (.preferences, "Preferences"), (.logs, "Logs"),
        ]
        for (location, folder) in locations {
            for match in matches(in: systemLibrary + "/" + folder, location: location, rules: rules) {
                let path = systemLibrary + "/" + folder + "/" + match.name
                found.append(ProtectedLeftover(path: path, reason: "Shared by every account: " + ownership(of: path, fallback: "in /Library"),
                                               evidence: match.evidence))
            }
        }
        // Helpers the app installs with SMJobBless, named in its Info.plist,
        // and any others named after its bundle ID.
        let helpers = privilegedHelperLabels(inBundleAt: app.resolvedPath)
        let helperFolder = systemLibrary + "/PrivilegedHelperTools"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: helperFolder))?.sorted() ?? [] {
            let evidence: LeftoverEvidence? = if helpers.contains(name) {
                .privilegedHelper(name)
            } else {
                rules.match(name, in: .applicationSupport, byHost: false).flatMap { match in
                    if case .appName = match.evidence { return nil }
                    return match.evidence
                }
            }
            if let evidence {
                found.append(ProtectedLeftover(path: helperFolder + "/" + name, reason: "Privileged helper: runs as root", evidence: evidence))
            }
        }
        return found
    }

    /// System extensions inside the bundle. They go to the Trash with it,
    /// but one that's turned on may need the app's own uninstall step.
    static func systemExtensions(inBundleAt bundle: String) -> [ProtectedLeftover] {
        let folder = bundle + "/Contents/Library/SystemExtensions"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".systemextension") }.sorted().map { name in
            ProtectedLeftover(path: folder + "/" + name,
                              reason: "System extension: turn it off from the app, or check System Settings > General > "
                                  + "Login Items & Extensions afterwards",
                              evidence: .insideApp)
        }
    }

    /// The labels under `SMPrivilegedExecutables` in the bundle's Info.plist.
    static func privilegedHelperLabels(inBundleAt bundle: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let helpers = plist["SMPrivilegedExecutables"] as? [String: Any] else { return [] }
        return Set(helpers.keys)
    }

    /// The bundle and its link, then launch agents, then each location's
    /// exact matches before its uncertain ones.
    static func ordered(_ items: [LeftoverItem]) -> [LeftoverItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.location != right.location { return left.location < right.location }
            if left.confidence != right.confidence { return left.confidence < right.confidence }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func dedupe(_ items: [ProtectedLeftover]) -> [ProtectedLeftover] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }

    // MARK: Matching rules

    /// The names that tie a file to the app, and the names that tie it to
    /// another app instead.
    struct MatchRules {
        /// The bundle ID, lowercased.
        let identifier: String?
        let shownIdentifier: String?
        let team: String?
        /// The app's name and its executable's, lowercased, when distinctive enough to look for.
        let names: Set<String>
        /// Other installed apps' bundle IDs, lowercased.
        let otherIdentifiers: Set<String>
        /// Another copy of this app (same bundle ID) installed elsewhere.
        let otherCopy: String?
        /// Another installed app with the same name.
        let sameName: String?

        /// App names too generic to match a folder on: an app called "Helper"
        /// says nothing about a folder called Helper.
        static let genericNames: Set<String> = [
            "app", "apps", "application", "helper", "install", "installer", "uninstall", "uninstaller", "setup", "update",
            "updater", "launcher", "agent", "service", "daemon", "utilities", "tools", "data", "cache", "caches", "logs",
            "preferences", "support", "temp", "tmp",
        ]

        init(app: InstalledApp, others: [InstalledApp]) {
            let identifier = app.bundleIdentifier?.trimmingCharacters(in: .whitespaces)
            self.identifier = identifier.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            shownIdentifier = self.identifier == nil ? nil : identifier
            team = app.signature.teamIdentifier
            let executable = app.executablePath.map { ($0 as NSString).lastPathComponent }
            names = Set([app.name, executable].compactMap { $0?.lowercased() }.filter { name in
                name.count >= 3 && !Self.genericNames.contains(name)
            })
            otherIdentifiers = Set(others.compactMap { $0.bundleIdentifier?.lowercased() })
            otherCopy = self.identifier.flatMap { identifier in
                others.first { $0.bundleIdentifier?.lowercased() == identifier }?.path
            }
            sameName = others.first { $0.name.caseInsensitiveCompare(app.name) == .orderedSame }?.path
        }

        /// Whether `name`, in a `location` folder, belongs to the app.
        func match(_ name: String, in location: LeftoverLocation,
                   byHost: Bool) -> (evidence: LeftoverEvidence, confidence: LeftoverConfidence)? {
            let lowered = name.lowercased()
            if location == .groupContainers { return groupMatch(lowered) }
            if let identifier, let shownIdentifier {
                if isExact(lowered, identifier: identifier, location: location, byHost: byHost) {
                    // A bundle ID without a dot ("Editor") could be anyone's folder name.
                    return (.bundleIdentifier(shownIdentifier), identifier.contains(".") ? .exact : .uncertain)
                }
                // Only for an ID with a dot, or "Editor" would claim every "Editor.…".
                if identifier.contains("."), lowered.hasPrefix(identifier + ".") {
                    let stem = Self.stem(of: name)
                    return belongsToAnotherApp(stem.lowercased()) ? nil : (.bundleIdentifierPrefix(stem), .uncertain)
                }
            }
            if location.matchesAppName, names.contains(lowered), !otherIdentifiers.contains(lowered) {
                return (.appName(name), .uncertain)
            }
            return nil
        }

        /// App-group folders are shared by design, so they're never exact.
        private func groupMatch(_ lowered: String) -> (evidence: LeftoverEvidence, confidence: LeftoverConfidence)? {
            if let identifier, let shownIdentifier,
               lowered == "group." + identifier || lowered.hasPrefix("group." + identifier + ".") {
                return (.appGroup(shownIdentifier), .uncertain)
            }
            if let team, lowered.hasPrefix(team.lowercased() + ".") {
                return (.teamIdentifier(team), .uncertain)
            }
            return nil
        }

        /// The bundle ID with the location's usual extension; in
        /// Preferences/ByHost, followed by this Mac's hardware UUID too.
        private func isExact(_ lowered: String, identifier: String, location: LeftoverLocation, byHost: Bool) -> Bool {
            if byHost {
                guard lowered.hasPrefix(identifier + "."), lowered.hasSuffix(".plist") else { return false }
                let host = lowered.dropFirst(identifier.count + 1).dropLast(".plist".count)
                return host.count >= 12 && host.allSatisfy { $0.isHexDigit || $0 == "-" }
            }
            return location.exactSuffixes.contains { lowered == identifier + $0.lowercased() }
        }

        /// An ID that's another app's, or starts with another app's that's
        /// longer than this one's: com.example.app.pro belongs to the Pro app.
        private func belongsToAnotherApp(_ stem: String) -> Bool {
            otherIdentifiers.contains { other in
                other.count > (identifier?.count ?? 0) && (stem == other || stem.hasPrefix(other + "."))
            }
        }

        /// The name without the extensions the locations add.
        static func stem(of name: String) -> String {
            for suffix in [".plist", ".savedState", ".binarycookies"] where name.lowercased().hasSuffix(suffix.lowercased()) {
                return String(name.dropLast(suffix.count))
            }
            return name
        }

        /// Why an exact match might not be this copy's alone.
        func caveat(for evidence: LeftoverEvidence) -> String? {
            switch evidence {
            case .bundleIdentifier, .bundleIdentifierPrefix, .appGroup:
                otherCopy.map { "Another copy of this app, at \($0), uses the same bundle ID" }
            case .appName:
                sameName.map { "Another app, at \($0), has the same name" }
            default:
                nil
            }
        }
    }

    // MARK: Permissions

    /// Whether this account can move the item: its folder has to be
    /// writable, and a folder (not a link) has to be writable itself, since
    /// moving it rewrites its parent link. Root-owned bundles from installer
    /// packages fail the second test, as they do in Finder.
    public static func canRemove(_ path: String) -> Bool {
        guard FileManager.default.isDeletableFile(atPath: path) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFDIR { return access(path, W_OK) == 0 }
        return true
    }

    /// "owned by root", or `fallback` when its owner isn't the reason.
    static func ownership(of path: String, fallback: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0 else { return fallback }
        return "owned by root"
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    // MARK: Size

    /// Disk space the item takes: a file's allocated size, or the total for
    /// everything in a folder. A link counts as itself, not what it points
    /// to. Nil if it's gone or told to stop.
    public static func allocatedSize(atPath path: String, isCancelled: () -> Bool = { false }) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFDIR {
            return InstalledApps.allocatedSize(ofBundleAt: path, isCancelled: isCancelled)
        }
        return UInt64(max(info.st_blocks, 0)) * 512
    }

    // MARK: Running processes

    /// Whether `path` is `bundle` or inside it.
    static func isInside(_ path: String, bundles: Set<String>) -> Bool {
        let path = InstalledApps.normalized(path)
        return bundles.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Sorts the processes running from the app by who has to stop them:
    /// you (quit first), its launch agents that are about to be unloaded, or
    /// another user. A process belongs to an agent when it runs the agent's
    /// program, so a kept-alive agent that restarts under a new PID still counts.
    public static func classify(_ processes: [BundleProcess], unloading agents: [LaunchItem], uid: uid_t = getuid()) -> RunningCheck {
        let programs = Set(agents.compactMap(\.program).map(InstalledApps.normalized))
        let agentPIDs = Set(agents.compactMap(\.pid))
        var check = RunningCheck()
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            if process.uid != uid {
                check.otherUsers.append(process)
            } else if agentPIDs.contains(process.pid) || programs.contains(InstalledApps.normalized(process.path)) {
                check.stopWithAgent.append(process)
            } else {
                check.needQuitting.append(process)
            }
        }
        return check
    }

    /// The processes, among `processes`, running from inside any of `bundles`.
    public static func processes(inside bundles: [String], among processes: [BundleProcess]) -> [BundleProcess] {
        let bundles = Set(bundles.map(InstalledApps.normalized))
        return processes.filter { isInside($0.path, bundles: bundles) }
    }

    /// Every process running from inside the bundles, read from the kernel.
    /// Paths of other users' processes are readable too, so a root helper
    /// running from the bundle shows up.
    public static func runningProcesses(inside bundles: [String]) -> [BundleProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let written = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        let all: [BundleProcess] = pids.prefix(Int(written)).compactMap { pid in
            guard pid > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return BundleProcess(pid: pid, uid: info.pbsi_uid, path: path)
        }
        return processes(inside: bundles, among: all)
    }

    // MARK: Launch agents

    /// The `launchctl` call that unloads an agent from your session.
    public static func unloadArguments(for item: LaunchItem, uid: uid_t) -> [String] {
        ["bootout", "gui/\(uid)/\(item.label)"]
    }

    /// Unloads a launch agent, so launchd stops it and won't start it again
    /// from a property list that's about to go. Nil when it's no longer
    /// loaded (including when it never was), else what went wrong.
    public static func unload(_ item: LaunchItem, uid: uid_t = getuid()) -> String? {
        let result = Launchctl.execute(unloadArguments(for: item, uid: uid))
        guard result.status != 0 else { return nil }
        // Booting out a job that isn't loaded fails harmlessly; check it's gone.
        let loaded = CommandRunner.execute("/bin/launchctl", ["print", "gui/\(uid)/\(item.label)"], capture: .output, timeout: 10)
        guard loaded?.status == 0 else { return nil }
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "launchctl bootout failed with status \(result.status)." : detail
    }

    // MARK: Order

    /// The order a removal runs in: unload the agents first so nothing
    /// relaunches from the app, then move the bundle (and its link), then
    /// the rest. If the bundle can't move, the rest stays put.
    public static func trashOrder(_ items: [LeftoverItem]) -> RemovalOrder {
        RemovalOrder(unload: items.compactMap(\.launchItem),
                     app: items.filter { $0.location == .app }.sorted { $0.evidence == .theApp && $1.evidence != .theApp },
                     rest: items.filter { $0.location != .app })
    }
}
