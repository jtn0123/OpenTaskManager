import Foundation

/// What an extension is for. System extensions run as their own processes
/// outside the kernel; kernel extensions (kexts) run inside it.
public enum ExtensionCategory: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case network
    case driver
    case endpointSecurity
    /// A system extension in a category this version doesn't know yet.
    case otherSystem
    case kernel

    public var title: String {
        switch self {
        case .network: "Network extension"
        case .driver: "Driver (DriverKit)"
        case .endpointSecurity: "Endpoint security"
        case .otherSystem: "System extension"
        case .kernel: "Kernel extension"
        }
    }

    public var isSystemExtension: Bool { self != .kernel }

    /// Maps the category systemextensionsctl prints, such as
    /// `com.apple.system_extension.network_extension`.
    public init(systemCategory identifier: String) {
        switch identifier.split(separator: ".").last {
        case "network_extension": self = .network
        case "driver_extension": self = .driver
        case "endpoint_security_extension": self = .endpointSecurity
        default: self = .otherSystem
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Where an extension stands, in plain words. Sorts with what needs you first.
public enum ExtensionStatus: Sendable, Codable, Hashable, Comparable {
    /// Installed, but macOS waits for someone to allow it in System Settings.
    case needsApproval
    /// A system extension that's enabled and running.
    case active
    /// A kernel extension loaded into the kernel and started.
    case loaded
    /// A kernel extension loaded but not started.
    case notStarted
    /// Enabled, but not the copy in use, such as an update waiting its turn.
    case enabled
    /// Allowed once, then turned off in System Settings.
    case disabled
    /// Its app removed it, and macOS deletes it at the next restart.
    case uninstalling
    /// Any other state, already made readable.
    case other(String)

    public var title: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .active: "Active"
        case .loaded: "Loaded"
        case .notStarted: "Not started"
        case .enabled: "Enabled"
        case .disabled: "Turned off"
        case .uninstalling: "Uninstalls at restart"
        case let .other(text): text
        }
    }

    /// Something only the person at the Mac can resolve.
    public var needsAttention: Bool { self == .needsApproval }

    /// One sentence on what the status means.
    public var explanation: String {
        switch self {
        case .needsApproval:
            "macOS is waiting for you to allow it in System Settings. It can't run until you do."
        case .active:
            "Enabled and running."
        case .loaded:
            "Loaded into the kernel and running."
        case .notStarted:
            "Loaded into the kernel, but it hasn't started running."
        case .enabled:
            "Enabled, but another copy is the one in use. macOS swaps them when the update is ready."
        case .disabled:
            "Installed but turned off, so it doesn't run. System Settings can turn it back on."
        case .uninstalling:
            "Its app asked for it to be removed. It stays until the next restart, then macOS deletes it."
        case .other:
            "macOS is part-way through installing, checking or removing it."
        }
    }

    // Coded as one string, the case name or the text of `.other`, so the
    // JSON from `otm drivers` reads "status": "active".

    private static let codes: [(code: String, status: Self)] = [
        ("needsApproval", .needsApproval), ("active", .active), ("loaded", .loaded), ("notStarted", .notStarted),
        ("enabled", .enabled), ("disabled", .disabled), ("uninstalling", .uninstalling),
    ]

    public init(from decoder: any Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        self = Self.codes.first { $0.code == code }?.status ?? .other(code)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if case let .other(text) = self {
            try container.encode(text)
        } else {
            try container.encode(Self.codes.first { $0.status == self }?.code ?? title)
        }
    }
}

/// One row of `systemextensionsctl list`: a network, DriverKit or endpoint
/// security extension an app installed and macOS allowed.
public struct SystemExtension: Sendable, Codable, Hashable {
    public let bundleID: String
    public let name: String
    /// `CFBundleShortVersionString`.
    public let version: String?
    /// `CFBundleVersion`, when it's printed.
    public let build: String?
    /// The developer's Team ID, nil when the row shows none.
    public let teamID: String?
    /// The raw category, such as `com.apple.system_extension.network_extension`.
    public let categoryIdentifier: String
    /// Where System Settings changes it, such as
    /// "System Settings > General > Login Items & Extensions > Network Extensions".
    public let settingsLocation: String?
    public let isEnabled: Bool
    public let isActive: Bool
    /// systemextensionsctl's own words, such as "activated enabled".
    public let state: String
    /// The app that installed it, when the system extension database says.
    public var appPath: String?

    public var category: ExtensionCategory { ExtensionCategory(systemCategory: categoryIdentifier) }

    /// Reads systemextensionsctl's state and the enabled and active columns.
    public var status: ExtensionStatus {
        let state = state.lowercased()
        if state.contains("waiting for user") { return .needsApproval }
        if state.contains("uninstall") { return .uninstalling }
        if state.hasPrefix("activated") {
            if state.contains("disabled") { return .disabled }
            if state.contains("upgrad") { return .other("Update waiting") }
            if state.contains("enabled") { return isActive ? .active : .enabled }
        }
        if state.hasPrefix("validating") { return .other("Being checked") }
        if state.hasPrefix("terminated") { return .other("Stopped") }
        let words = self.state.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? .other("Unknown") : .other(words.prefix(1).uppercased() + words.dropFirst())
    }
}

/// A loaded kernel extension, as the kernel reports it.
public struct KernelExtension: Sendable, Codable, Hashable {
    /// The load tag (kmutil's Index). Other kexts name their dependencies by it.
    public let loadTag: Int
    public let bundleID: String
    public let version: String?
    /// How many other kexts hold on to it, mostly by linking against it.
    public let references: Int
    /// Nil for kernel interfaces, which have no code of their own.
    public let loadAddress: UInt64?
    public let size: UInt64
    public let wiredSize: UInt64
    /// The executable's UUID, upper case with dashes.
    public let uuid: String?
    /// Load tags of the kexts it links against.
    public let linkedAgainst: [Int]
    /// Where it was loaded from. The kernel only keeps this as a hint, and
    /// kmutil doesn't print it.
    public let path: String?
    /// A kernel programming interface such as `com.apple.kpi.bsd`: part of the
    /// kernel itself that other kexts link against.
    public let isInterface: Bool
    public let isStarted: Bool

    public init(loadTag: Int, bundleID: String, version: String?, references: Int, loadAddress: UInt64?,
                size: UInt64, wiredSize: UInt64, uuid: String?, linkedAgainst: [Int], path: String?,
                isInterface: Bool, isStarted: Bool) {
        self.loadTag = loadTag
        self.bundleID = bundleID
        self.version = version
        self.references = references
        self.loadAddress = loadAddress
        self.size = size
        self.wiredSize = wiredSize
        self.uuid = uuid
        self.linkedAgainst = linkedAgainst
        self.path = path
        self.isInterface = isInterface
        self.isStarted = isStarted
    }

    /// The bundle's file name without `.kext` ("AppleUSBAudio", "smbfs"), or
    /// the last part of its bundle ID when the path is unknown.
    public var name: String {
        if let path, let file = path.split(separator: "/").last, file.hasSuffix(".kext") {
            return String(file.dropLast(5))
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// A system or kernel extension, as a row of the Drivers page. Exactly one
/// of `systemExtension` and `kernelExtension` is set.
public struct ExtensionItem: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bundleID: String
    /// Empty when unknown, so the column still sorts.
    public let version: String
    public let category: ExtensionCategory
    public let publisher: LaunchItemPublisher
    public let status: ExtensionStatus
    public let systemExtension: SystemExtension?
    public let kernelExtension: KernelExtension?

    /// The kernel interfaces (`com.apple.kpi.*`) are part of the kernel, not
    /// something that was added to it.
    public var isKernelInterface: Bool { kernelExtension?.isInterface == true }

    /// The category's name, except that kernel interfaces say what they are.
    public var kind: String { isKernelInterface ? "Kernel interface" : category.title }

    public init(_ item: SystemExtension, id: String) {
        self.id = id
        name = item.name.isEmpty ? LaunchItems.displayName(forLabel: item.bundleID) : item.name
        bundleID = item.bundleID
        version = item.version ?? ""
        category = item.category
        publisher = Extensions.publisher(bundleID: item.bundleID, path: nil)
        status = item.status
        systemExtension = item
        kernelExtension = nil
    }

    public init(_ item: KernelExtension) {
        id = "kext:" + item.bundleID
        name = item.name
        bundleID = item.bundleID
        version = item.version ?? ""
        category = .kernel
        publisher = Extensions.publisher(bundleID: item.bundleID, path: item.path)
        status = item.isStarted ? .loaded : .notStarted
        systemExtension = nil
        kernelExtension = item
    }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let fields = [name, bundleID, category.title, systemExtension?.teamID ?? "", kernelExtension?.path ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The counts across the top of the Drivers page.
public struct ExtensionSummary: Sendable, Codable, Hashable {
    public let systemExtensions: Int
    public let thirdPartyKernelExtensions: Int
    public let loadedKernelExtensions: Int
    public let needsAttention: Int

    public init(_ items: [ExtensionItem]) {
        systemExtensions = items.filter(\.category.isSystemExtension).count
        thirdPartyKernelExtensions = items.filter { $0.category == .kernel && $0.publisher == .thirdParty }.count
        loadedKernelExtensions = items.filter { $0.category == .kernel }.count
        needsAttention = items.filter(\.status.needsAttention).count
    }
}

/// One read of everything loaded. A source that couldn't be read is flagged,
/// so the page can say "unknown" rather than "none".
public struct ExtensionScan: Sendable, Codable, Hashable {
    public let items: [ExtensionItem]
    public let readSystemExtensions: Bool
    public let readKernelExtensions: Bool

    public var summary: ExtensionSummary { ExtensionSummary(items) }

    public init(items: [ExtensionItem], readSystemExtensions: Bool, readKernelExtensions: Bool) {
        self.items = items
        self.readSystemExtensions = readSystemExtensions
        self.readKernelExtensions = readKernelExtensions
    }

    /// The kexts it links against, by bundle ID, kernel interfaces last.
    public func linkedAgainst(_ kext: KernelExtension) -> [String] {
        let byTag = Dictionary(kernelExtensions.map { ($0.loadTag, $0) }, uniquingKeysWith: { first, _ in first })
        return kext.linkedAgainst.compactMap { byTag[$0] }
            .sorted { ($0.isInterface ? 1 : 0, $0.bundleID) < ($1.isInterface ? 1 : 0, $1.bundleID) }
            .map(\.bundleID)
    }

    /// The kexts that link against it, by bundle ID.
    public func linkedBy(_ kext: KernelExtension) -> [String] {
        kernelExtensions.filter { $0.linkedAgainst.contains(kext.loadTag) }.map(\.bundleID).sorted()
    }

    private var kernelExtensions: [KernelExtension] { items.compactMap(\.kernelExtension) }
}

/// Reads the system extensions macOS has allowed and the kexts loaded in the
/// kernel. Neither needs administrator rights.
public enum Extensions {
    /// Runs systemextensionsctl and asks the kernel for its kexts, which takes
    /// a few hundredths of a second, so call it off the main actor.
    public static func scan() -> ExtensionScan {
        let listing = CommandRunner.run("/usr/bin/systemextensionsctl", ["list"], timeout: 5)
        var systemExtensions = listing.map(SystemExtensionList.parse) ?? []
        if !systemExtensions.isEmpty, let database = try? Data(contentsOf: URL(fileURLWithPath: SystemExtensionList.databasePath)) {
            systemExtensions = SystemExtensionList.attachApps(systemExtensions, database: database)
        }
        let kexts = KernelExtensionList.read()
        return ExtensionScan(items: items(systemExtensions: systemExtensions, kernelExtensions: kexts ?? []),
                             readSystemExtensions: listing.map(SystemExtensionList.isListing) ?? false,
                             readKernelExtensions: kexts != nil)
    }

    /// System extensions first, in listing order, then kexts by load tag.
    /// A system extension can be listed twice (an old copy waiting to go and
    /// its update), so repeated identities get a numbered ID.
    public static func items(systemExtensions: [SystemExtension], kernelExtensions: [KernelExtension]) -> [ExtensionItem] {
        var seen: [String: Int] = [:]
        let system = systemExtensions.map { item in
            let key = "sysext:\(item.teamID ?? "-"):\(item.bundleID):\(item.version ?? ""):\(item.state)"
            seen[key, default: 0] += 1
            return ExtensionItem(item, id: seen[key] == 1 ? key : "\(key)#\(seen[key] ?? 0)")
        }
        return system + kernelExtensions.sorted { $0.loadTag < $1.loadTag }.map(ExtensionItem.init)
    }

    /// Apple's own extensions carry an Apple bundle ID or live under /System.
    public static func publisher(bundleID: String, path: String?) -> LaunchItemPublisher {
        bundleID.lowercased().hasPrefix("com.apple.") || path?.hasPrefix("/System/") == true ? .apple : .thirdParty
    }
}
