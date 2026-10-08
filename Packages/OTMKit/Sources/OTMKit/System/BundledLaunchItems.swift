import Foundation

/// The work done by a bounded bundle scan, including listings of missing folders.
public struct BundledLaunchDiscovery: Sendable {
    public let items: [LaunchItem]
    public let appCount: Int
    public let directoryReads: Int
}

extension LaunchItems {
    /// The Apps page's application folders, with /System left out. No Spotlight
    /// query or disk-wide walk is needed to find the registrations apps ship.
    public static func registrationAppPaths(home: String = NSHomeDirectory()) -> [String] {
        InstalledApps.standardFolders(home: home).filter { !$0.hasPrefix("/System/") }
            .flatMap { InstalledApps.bundles(inFolder: $0, depth: InstalledApps.folderDepth) }
    }

    /// Exactly three directory listings per app, with no descent into helpers,
    /// executable inspection or signature checks. Call only on opening or Refresh.
    public static func discoverBundled(in appPaths: [String]) -> BundledLaunchDiscovery {
        let apps = InstalledApps.deduplicate(appPaths).filter { location in
            location.path.hasSuffix(".app") && outsideSystem(location.path) && outsideSystem(location.resolved)
        }
        var items: [LaunchItem] = []
        for app in apps {
            items += bundledPlists(app: app.path, folder: "LaunchAgents", scope: .userAgent, source: .bundledAgent)
            items += bundledPlists(app: app.path, folder: "LaunchDaemons", scope: .daemon, source: .bundledDaemon)
            let folder = app.path + "/Contents/Library/LoginItems"
            for path in bundleEntries(folder, suffix: ".app") {
                items.append(loginItem(at: path, owner: app.path))
            }
        }
        return BundledLaunchDiscovery(items: items, appCount: apps.count, directoryReads: apps.count * 3)
    }

    private static func bundledPlists(app: String, folder: String, scope: LaunchItemScope,
                                      source: LaunchItemSource) -> [LaunchItem] {
        bundleEntries(app + "/Contents/Library/" + folder, suffix: ".plist").map { path in
            let url = URL(fileURLWithPath: path)
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return item(plist: FileManager.default.contents(atPath: path), path: path, scope: scope,
                        modified: modified, source: source, owningAppPath: appBundlePath(forProgram: app))
        }
    }

    private static func bundleEntries(_ folder: String, suffix: String) -> [String] {
        guard outsideSystem(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { $0.hasSuffix(suffix) }.sorted().map { folder + "/" + $0 }.filter(outsideSystem)
    }

    private static func outsideSystem(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved != "/System" && !resolved.hasPrefix("/System/")
    }

    private static func loginItem(at path: String, owner: String) -> LaunchItem {
        let infoPath = path + "/Contents/Info.plist"
        let info = outsideSystem(infoPath) ? InstalledApps.propertyList(atPath: infoPath) : [:]
        let identifier = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let label = identifier ?? (path as NSString).lastPathComponent
        let executable = (info["CFBundleExecutable"] as? String).flatMap { name -> String? in
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return path + "/Contents/MacOS/" + name
        }
        return LaunchItem(label: label, name: displayName(forLabel: label), plistPath: path, modified: nil,
                          scope: .userAgent, source: .loginItem, owningAppPath: appBundlePath(forProgram: owner),
                          publisher: publisher(plistPath: path, label: label), program: executable, arguments: [],
                          triggers: LaunchTriggers(), disabledInPlist: false, isMissingLabel: identifier == nil, isUnreadable: info.isEmpty)
    }

    /// Adds only jobs no read plist or helper identifies. Application and anonymous
    /// process labels describe launches, rather than persistent registrations, and
    /// Apple's own jobs without a file are the XPC services and per-instance workers
    /// macOS starts on demand (about a hundred on a typical Mac), not startup items.
    public static func loadedWithoutFiles(_ items: [LaunchItem], userJobs: [String: LaunchJobStatus],
                                          systemJobs: [String: LaunchJobStatus]) -> [LaunchItem] {
        let labels = Set(items.filter { !$0.isMissingLabel }.map(\.label))
        func unmatched(_ jobs: [String: LaunchJobStatus], scope: LaunchItemScope) -> [LaunchItem] {
            jobs.keys.sorted().compactMap { label in
                guard !labels.contains(label), !label.hasPrefix("application."), !isAnonymousLabel(label),
                      publisher(plistPath: "", label: label) == .thirdParty else { return nil }
                return LaunchItem(label: label, name: displayName(forLabel: label), plistPath: "", modified: nil,
                                  scope: scope, source: .loadedWithoutFile, owningAppPath: nil,
                                  publisher: publisher(plistPath: "", label: label), program: nil, arguments: [],
                                  triggers: LaunchTriggers(), disabledInPlist: false, isMissingLabel: false, isUnreadable: false,
                                  job: jobs[label])
            }
        }
        return unmatched(userJobs, scope: .userAgent) + unmatched(systemJobs, scope: .daemon)
    }

    private static func isAnonymousLabel(_ label: String) -> Bool {
        let parts = label.split(separator: ".")
        return parts.contains("anonymous")
    }
}
