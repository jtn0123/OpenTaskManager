import Foundation

/// Where an app came from. Third-party apps sort first.
public enum AppKind: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case thirdParty
    case appStore
    case apple

    public var title: String {
        switch self {
        case .thirdParty: "Third party"
        case .appStore: "App Store"
        case .apple: "Apple"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Which processors an app's main executable is built for.
public enum AppArchitecture: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    /// Apple silicon only.
    case appleSilicon
    /// Both Apple silicon and Intel.
    case universal
    /// Intel only: on Apple silicon it runs under Rosetta.
    case intel
    /// Only 32-bit or PowerPC code, which current macOS can't run.
    case unsupported
    /// No executable, or one that isn't Mach-O (such as a script).
    case unknown

    public init(slices: [MachOSlice]?) {
        guard let slices, !slices.isEmpty else {
            self = .unknown
            return
        }
        let arm = slices.contains(where: \.isARM64)
        let intel = slices.contains(where: \.isIntel64)
        switch (arm, intel) {
        case (true, true): self = .universal
        case (true, false): self = .appleSilicon
        case (false, true): self = .intel
        case (false, false): self = .unsupported
        }
    }

    public var title: String {
        switch self {
        case .appleSilicon: "Apple silicon"
        case .universal: "Universal"
        case .intel: "Intel only"
        case .unsupported: "32-bit or PowerPC"
        case .unknown: "Unknown"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// An application bundle on this Mac and what can be read from it without
/// opening it.
public struct InstalledApp: Sendable, Codable, Hashable, Identifiable {
    /// The resolved path, so two links to one bundle are one app while two
    /// copies of the same app (say, a release and a beta) stay separate.
    public var id: String { resolvedPath }
    /// Where it was found, such as /Applications/Safari.app.
    public let path: String
    /// `path` with symbolic links resolved.
    public let resolvedPath: String
    /// The name Finder shows.
    public let name: String
    public let bundleIdentifier: String?
    /// `CFBundleShortVersionString`, such as "17.2".
    public let version: String?
    /// `CFBundleVersion`, the build number.
    public let build: String?
    /// `LSMinimumSystemVersion`.
    public let minimumSystemVersion: String?
    public let executablePath: String?
    public let kind: AppKind
    /// Has a Mac App Store receipt (or, for iPhone and iPad apps, App Store metadata).
    public let hasAppStoreReceipt: Bool
    /// An iPhone or iPad app running on Apple silicon, wrapped in a Mac bundle.
    public let isiOSApp: Bool
    /// The executable's architectures; nil when it isn't a Mach-O file.
    public let slices: [MachOSlice]?
    public let architecture: AppArchitecture
    public let signature: CodeSignature
    /// Spotlight's `kMDItemLastUsedDate`; nil when Spotlight doesn't know.
    public let lastOpened: Date?
    /// Spotlight's `kMDItemDateAdded`: when it arrived in its folder.
    public let added: Date?
    /// launchd jobs that run something inside the bundle or carry its bundle ID in their label.
    public var launchItems: [LaunchItem]

    public init(path: String, resolvedPath: String, name: String, bundleIdentifier: String?, version: String?,
                build: String?, minimumSystemVersion: String?, executablePath: String?, kind: AppKind,
                hasAppStoreReceipt: Bool, isiOSApp: Bool, slices: [MachOSlice]?, signature: CodeSignature,
                lastOpened: Date?, added: Date?, launchItems: [LaunchItem] = []) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.executablePath = executablePath
        self.kind = kind
        self.hasAppStoreReceipt = hasAppStoreReceipt
        self.isiOSApp = isiOSApp
        self.slices = slices
        self.architecture = AppArchitecture(slices: slices)
        self.signature = signature
        self.lastOpened = lastOpened
        self.added = added
        self.launchItems = launchItems
    }

    /// "17.2 (20617.1.17)", or just one of them when the other is missing or the same.
    public var versionText: String {
        switch (version, build) {
        case let (version?, build?) where build != version: "\(version) (\(build))"
        case let (version?, _): version
        case let (nil, build?): build
        case (nil, nil): "—"
        }
    }

    /// The architectures by name: "arm64, x86_64".
    public var sliceNames: String? {
        slices.map { $0.map(\.name).joined(separator: ", ") }
    }

    /// The folder it's in, with your home folder shortened to "~".
    public func folder(home: String = NSHomeDirectory()) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == home || parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }

    /// Its launch items that start without being asked: at login or boot,
    /// kept alive, on a timer or schedule, or when a file changes. Items that
    /// only start when another process calls on them aren't counted.
    public var selfStartingItems: [LaunchItem] {
        launchItems.filter(\.startsOnItsOwn)
    }

    public var startsItself: Bool { !selfStartingItems.isEmpty }

    /// Text for the Startup page's search (which looks at each item's name,
    /// label, program and property list path) that finds as many of this
    /// app's launch items as possible: usually the bundle ID, otherwise the
    /// bundle path their programs share. Nil when the app has none.
    public var startupSearchText: String? {
        guard !launchItems.isEmpty else { return nil }
        func found(by text: String) -> Int {
            launchItems.filter { item in
                [item.name, item.label, item.program ?? "", item.plistPath].contains { $0.localizedCaseInsensitiveContains(text) }
            }.count
        }
        // Ties keep the earlier, more specific candidate.
        return [bundleIdentifier, resolvedPath, path, name].compactMap { $0 }.max { found(by: $0) < found(by: $1) }
    }

    /// Matches a search against the name, bundle ID, path and signing team.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let fields = [name, bundleIdentifier, path, signature.teamIdentifier, signature.developerName]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

public extension LaunchItem {
    /// Enabled, and started by launchd itself rather than at another process's request.
    var startsOnItsOwn: Bool {
        guard !isMissingLabel, !isUnreadable, !isDisabled else { return false }
        return timing != .onDemand && timing != .unknown
    }
}
