import CoreServices
import Foundation

/// A bundle path as found, and with links resolved.
public struct BundleLocation: Sendable, Hashable {
    public let path: String
    public let resolved: String

    public init(path: String, resolved: String) {
        self.path = path
        self.resolved = resolved
    }
}

/// A running app as NSWorkspace reports it, reduced to what's needed to
/// match it to an installed bundle.
public struct RunningAppReference: Sendable, Hashable {
    public let pid: Int32
    public let bundlePath: String?
    public let bundleIdentifier: String?

    public init(pid: Int32, bundlePath: String?, bundleIdentifier: String?) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Finds the applications installed on this Mac and reads what each one is.
public enum InstalledApps {
    /// Folders searched directly. Plain folders inside them (Utilities, a
    /// vendor's folder) are searched too, but bundles are never opened.
    public static func standardFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"]
    }

    /// Apps outside those folders that people still think of as apps.
    static let standardBundles = ["/System/Library/CoreServices/Finder.app"]

    /// How many folders deep to look: /Applications/Vendor/Hub/Editor/1.0/Editor.app is five.
    static let folderDepth = 5

    /// Finds every app in the standard folders and, through Spotlight, the
    /// rest of the startup disk, then reads each one and the launchd jobs
    /// that belong to it. Reads a few hundred bundles and runs launchctl, so
    /// call it off the main actor. Sizes aren't included: see `allocatedSize`.
    public static func scan(home: String = NSHomeDirectory(), useSpotlight: Bool = true,
                            launchItems: [LaunchItem]? = nil, width: Int = 6) -> [InstalledApp] {
        var candidates = standardFolders(home: home).flatMap { bundles(inFolder: $0, depth: folderDepth) }
        candidates += standardBundles.filter { FileManager.default.fileExists(atPath: $0) }
        if useSpotlight {
            candidates += spotlightBundles().filter { isListable(spotlightPath: $0, home: home) }
        }
        let locations = deduplicate(candidates)
        let apps = BoundedWork.map(locations, width: width) { read(bundleAt: $0.path, resolvedPath: $0.resolved) }
        return attach(launchItems ?? LaunchItems.scan(), to: apps.compactMap { $0 })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Finding bundles

    /// The .app bundles in `folder` and the plain folders below it, down to `depth` levels.
    public static func bundles(inFolder folder: String, depth: Int) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if url.pathExtension.lowercased() == "app" {
                found.append(url.path)
                walker.skipDescendants()
            } else if walker.level >= depth {
                walker.skipDescendants()
            }
        }
        return found
    }

    /// Every application bundle Spotlight has indexed, on any volume.
    static func spotlightBundles() -> [String] {
        let predicate = "kMDItemContentType == 'com.apple.application-bundle'" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let result = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            return MDItemCopyAttribute(item, kMDItemPath) as? String
        }
    }

    /// Package extensions whose insides hold helpers rather than apps.
    static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "systemextension", "appbundle",
    ]

    /// Folders whose apps aren't installed apps: a bundle's insides, build
    /// caches, and Script Editor's droplet templates.
    static let excludedFolders: Set<String> = ["Contents", "node_modules", "DerivedData", "Templates"]

    /// Whether an app Spotlight found belongs in the list. Helpers inside
    /// other bundles, macOS internals, the Trash, hidden, build-cache and
    /// template folders, temporary copies, disk images and other drives'
    /// non-app folders are left out; an app in, say, ~/Downloads stays.
    public static func isListable(spotlightPath: String, home: String = NSHomeDirectory()) -> Bool {
        let path = normalized(spotlightPath)
        guard path.lowercased().hasSuffix(".app") else { return false }
        for component in path.split(separator: "/").dropLast() {
            if component.hasPrefix(".") || excludedFolders.contains(String(component)) { return false }
            if bundleExtensions.contains((String(component) as NSString).pathExtension.lowercased()) { return false }
        }
        // /System's user-facing apps come from the standard folders; the
        // rest of /System and /Library/Apple is macOS's own machinery.
        let excluded = ["/System/", "/Library/Apple/", "/private/", "/tmp/", "/var/", "/Library/Developer/",
                        home + "/Library/Developer/"]
        if excluded.contains(where: path.hasPrefix) { return false }
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            return parts.count >= 4 && parts[2] == "Applications"
        }
        return true
    }

    /// Drops repeats, keeping the first place each bundle was found. Two
    /// paths are the same bundle when they resolve to the same place.
    public static func deduplicate(_ paths: [String], resolve: (String) -> String = resolved) -> [BundleLocation] {
        var seen = Set<String>()
        var locations: [BundleLocation] = []
        for path in paths {
            let path = normalized(path)
            let resolved = normalized(resolve(path))
            if seen.insert(resolved).inserted {
                locations.append(BundleLocation(path: path, resolved: resolved))
            }
        }
        return locations
    }

    /// Tidies a path and maps the data volume's firmlinked copy of a folder
    /// (/System/Volumes/Data/Applications) to the usual one (/Applications).
    public static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        let dataVolume = "/System/Volumes/Data"
        if path.hasPrefix(dataVolume + "/") { path.removeFirst(dataVolume.count) }
        return path
    }

    /// `path` with symbolic links resolved.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Reading a bundle

    /// Reads one bundle: its Info.plist, executable header, signature and
    /// Spotlight dates. Nil when there's no bundle folder at `resolvedPath`.
    public static func read(bundleAt path: String, resolvedPath: String) -> InstalledApp? {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        // iPhone and iPad apps arrive wrapped: Foo.app/WrappedBundle links to Wrapper/Foo.app,
        // a flat iOS bundle with no Contents folder.
        let wrapped = resolvedPath + "/WrappedBundle"
        let isiOSApp = fileManager.fileExists(atPath: wrapped + "/Info.plist")
        let contents = isiOSApp ? resolved(wrapped) : resolvedPath + "/Contents"
        let info = propertyList(atPath: contents + "/Info.plist")
        let bundleIdentifier = info["CFBundleIdentifier"] as? String
        let executable = (info["CFBundleExecutable"] as? String).map { contents + (isiOSApp ? "/" : "/MacOS/") + $0 }
        let receipt = isiOSApp ? resolvedPath + "/Wrapper/iTunesMetadata.plist" : contents + "/_MASReceipt/receipt"
        let hasReceipt = fileManager.fileExists(atPath: receipt)
        let signature = CodeSigning.signature(atPath: isiOSApp ? contents : resolvedPath)
        let dates = spotlightDates(path) ?? (path == resolvedPath ? nil : spotlightDates(resolvedPath))
        return InstalledApp(
            path: path, resolvedPath: resolvedPath, name: displayName(path),
            bundleIdentifier: bundleIdentifier,
            version: nonEmpty(info["CFBundleShortVersionString"]), build: nonEmpty(info["CFBundleVersion"]),
            minimumSystemVersion: nonEmpty(info["LSMinimumSystemVersion"] ?? info["MinimumOSVersion"]),
            executablePath: executable,
            kind: kind(path: path, resolvedPath: resolvedPath, bundleIdentifier: bundleIdentifier,
                       hasAppStoreReceipt: hasReceipt, signer: signature.signer),
            hasAppStoreReceipt: hasReceipt, isiOSApp: isiOSApp,
            slices: executable.flatMap(MachO.slices(atPath:)), signature: signature,
            lastOpened: dates?.lastUsed, added: dates?.added
        )
    }

    /// Apple's when it's part of macOS, or carries Apple's bundle ID and
    /// signature (Xcode, Pages); the App Store's when it has a store receipt
    /// or the store's signature; otherwise a third party's.
    public static func kind(path: String, resolvedPath: String, bundleIdentifier: String?,
                            hasAppStoreReceipt: Bool, signer: AppSigner) -> AppKind {
        if path.hasPrefix("/System/") || resolvedPath.hasPrefix("/System/") { return .apple }
        let applesIdentifier = bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true
        if applesIdentifier, signer == .apple || signer == .appStore { return .apple }
        return hasAppStoreReceipt || signer == .appStore ? .appStore : .thirdParty
    }

    /// The name Finder shows, without the ".app" it may add when extensions are on.
    static func displayName(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func propertyList(atPath path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// When Spotlight last saw the app opened, and when it arrived. Nil when
    /// Spotlight has no record of the path.
    static func spotlightDates(_ path: String) -> (lastUsed: Date?, added: Date?)? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else { return nil }
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        return lastUsed == nil && added == nil ? nil : (lastUsed, added)
    }

    // MARK: Size

    /// Disk space the bundle takes: the allocated size of every file in it.
    /// Large apps hold tens of thousands of files, so this can take a second
    /// or more; it checks `isCancelled` as it goes and returns nil if told to stop.
    public static func allocatedSize(ofBundleAt path: String, isCancelled: () -> Bool = { false }) -> UInt64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: UInt64 = 0
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited.isMultiple(of: 500), isCancelled() { return nil }
            total += UInt64(max((try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0, 0))
        }
        return total
    }

    // MARK: Matching

    /// The launchd jobs that belong to `app`: those whose program or
    /// arguments point inside the bundle, and those labelled with its bundle
    /// ID ("com.example.app" or "com.example.app.helper").
    public static func launchItems(for app: InstalledApp, in items: [LaunchItem]) -> [LaunchItem] {
        let bundles = Set([app.path, app.resolvedPath])
        let identifier = app.bundleIdentifier?.lowercased()
        return items.filter { item in
            let paths = ([item.program].compactMap { $0 } + item.arguments).filter { $0.hasPrefix("/") }.map(normalized)
            let pointsInside = paths.contains { path in
                bundles.contains(path) || bundles.contains { path.hasPrefix($0 + "/") }
            }
            if pointsInside { return true }
            guard let identifier, !identifier.isEmpty else { return false }
            let label = item.label.lowercased()
            return label == identifier || label.hasPrefix(identifier + ".")
        }
    }

    /// Gives each app the launchd jobs that belong to it.
    public static func attach(_ items: [LaunchItem], to apps: [InstalledApp]) -> [InstalledApp] {
        apps.map { app in
            var app = app
            app.launchItems = launchItems(for: app, in: items)
            return app
        }
    }

    /// The PIDs running each app. A process matches the bundle it was opened
    /// from; one opened from somewhere else (a disk image, a quarantine copy)
    /// matches by bundle ID, as long as only one installed app has that ID.
    public static func runningPIDs(of apps: [InstalledApp], running: [RunningAppReference],
                                   resolve: (String) -> String = resolved) -> [InstalledApp.ID: [Int32]] {
        var byPath: [String: InstalledApp.ID] = [:]
        var byIdentifier: [String: [InstalledApp.ID]] = [:]
        for app in apps {
            byPath[app.path] = app.id
            byPath[app.resolvedPath] = app.id
            if let identifier = app.bundleIdentifier?.lowercased() { byIdentifier[identifier, default: []].append(app.id) }
        }
        var pids: [InstalledApp.ID: [Int32]] = [:]
        for process in running {
            var match = process.bundlePath.map(normalized).flatMap { byPath[$0] ?? byPath[normalized(resolve($0))] }
            if match == nil, let identifier = process.bundleIdentifier?.lowercased(),
               let candidates = byIdentifier[identifier], candidates.count == 1 {
                match = candidates[0]
            }
            if let match { pids[match, default: []].append(process.pid) }
        }
        return pids.mapValues { $0.sorted() }
    }
}
