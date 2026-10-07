import Foundation

/// Where something an app left behind lives. The order is the review's order.
public enum LeftoverLocation: String, Sendable, Hashable, CaseIterable, Comparable {
    /// The bundle itself, or a link to it.
    case app
    case launchAgents
    case preferences
    case applicationSupport
    case caches
    case containers
    case groupContainers
    case applicationScripts
    case savedState
    case httpStorages
    case webKit
    case logs

    public var title: String {
        switch self {
        case .app: "App"
        case .launchAgents: "Launch agents"
        case .preferences: "Preferences"
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .applicationScripts: "Application Scripts"
        case .savedState: "Saved Application State"
        case .httpStorages: "HTTP storage"
        case .webKit: "WebKit"
        case .logs: "Logs"
        }
    }

    /// The folders under a Library folder that hold this kind of item.
    var folders: [String] {
        switch self {
        case .app: []
        case .launchAgents: ["LaunchAgents"]
        case .preferences: ["Preferences", "Preferences/ByHost"]
        case .applicationSupport: ["Application Support"]
        case .caches: ["Caches"]
        case .containers: ["Containers"]
        case .groupContainers: ["Group Containers"]
        case .applicationScripts: ["Application Scripts"]
        case .savedState: ["Saved Application State"]
        case .httpStorages: ["HTTPStorages"]
        case .webKit: ["WebKit"]
        case .logs: ["Logs"]
        }
    }

    /// What follows the bundle ID in an item named exactly after it:
    /// com.example.app.plist, com.example.app.savedState.
    var exactSuffixes: [String] {
        switch self {
        case .preferences: [".plist"]
        case .savedState: [".savedState"]
        case .httpStorages: ["", ".binarycookies"]
        default: [""]
        }
    }

    /// Whether a folder with the app's name is worth showing here. Apps
    /// often name these after themselves rather than their bundle ID.
    var matchesAppName: Bool {
        [.applicationSupport, .caches, .logs].contains(self)
    }

    /// macOS asks before one app reads another's container, so their sizes
    /// aren't measured: opening the review shouldn't raise a privacy prompt.
    public var isMeasured: Bool {
        self != .containers && self != .groupContainers
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Why an item is thought to belong to an app. Shown beside each item, since
/// a name alone doesn't prove who owns a file.
public enum LeftoverEvidence: Sendable, Hashable {
    /// The app bundle itself.
    case theApp
    /// A symbolic link to the bundle, where the app was found.
    case linkToApp
    /// A launch agent whose program, or one of its arguments, is inside the bundle.
    case runsFromApp(program: String)
    /// Named exactly after the bundle ID, with the folder's usual extension.
    case bundleIdentifier(String)
    /// Named after an ID that starts with the bundle ID, such as a helper's
    /// or an extension's: com.example.app.helper.
    case bundleIdentifierPrefix(String)
    /// An app-group folder named after the bundle ID: group.com.example.app.
    case appGroup(String)
    /// An app-group folder that starts with the app's signing team.
    case teamIdentifier(String)
    /// A launch agent labelled with the bundle ID, or an ID that starts with it.
    case launchLabel(String)
    /// Named like the app, which is a guess.
    case appName(String)
    /// Listed in the app's Info.plist as a helper it installs with administrator rights.
    case privilegedHelper(String)
    /// Inside the app's bundle.
    case insideApp

    /// One line for the review: "Named after com.example.app".
    public func description(bundlePath: String) -> String {
        switch self {
        case .theApp: "The app itself"
        case .linkToApp: "A link to the app, where it was found"
        case let .runsFromApp(program):
            "Runs \(Self.inside(program, bundlePath: bundlePath)) from inside the app"
        case let .bundleIdentifier(identifier): "Named after \(identifier)"
        case let .bundleIdentifierPrefix(identifier): "Named after \(identifier), which starts with the app's bundle ID"
        case let .appGroup(identifier): "App group named after \(identifier); other apps can share it"
        case let .teamIdentifier(team): "Same team ID, \(team); other apps from this developer can share it"
        case let .launchLabel(label): "Labelled \(label)"
        case let .appName(name): "Same name as the app, \(name)"
        case let .privilegedHelper(label): "The app's Info.plist names \(label) as its privileged helper"
        case .insideApp: "Inside the app"
        }
    }

    /// "Contents/MacOS/helper" for a path inside the bundle, else the path.
    static func inside(_ path: String, bundlePath: String) -> String {
        path.hasPrefix(bundlePath + "/") ? String(path.dropFirst(bundlePath.count + 1)) : path
    }
}

/// How sure the match is, which decides whether it starts selected.
public enum LeftoverConfidence: Sendable, Hashable, Comparable {
    /// Goes with the app and can't be left behind: the bundle, a link to it,
    /// and launch agents that run a program inside it.
    case required
    /// Named exactly after the bundle ID: selected to start with.
    case exact
    /// A name, team or app-group match, or an exact match another installed
    /// copy also uses: shown, but left unselected.
    case uncertain
}

/// Something in your home folder that can go to the Trash with an app.
public struct LeftoverItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let location: LeftoverLocation
    public let evidence: LeftoverEvidence
    public let confidence: LeftoverConfidence
    /// Why an otherwise exact match isn't certain, such as another copy of the app.
    public let caveat: String?
    /// The launch agent to unload before its property list goes.
    public let launchItem: LaunchItem?

    public init(path: String, location: LeftoverLocation, evidence: LeftoverEvidence, confidence: LeftoverConfidence,
                caveat: String? = nil, launchItem: LaunchItem? = nil) {
        self.path = path
        self.location = location
        self.evidence = evidence
        self.confidence = confidence
        self.caveat = caveat
        self.launchItem = launchItem
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var startsSelected: Bool { confidence != .uncertain }
    public var isUncertain: Bool { confidence == .uncertain }
}

/// Something that belongs to the app but that OpenTaskManager won't move:
/// it needs administrator rights or the vendor's own uninstaller.
public struct ProtectedLeftover: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Why it's left alone: "Launch daemon, owned by root".
    public let reason: String
    public let evidence: LeftoverEvidence

    public init(path: String, reason: String, evidence: LeftoverEvidence) {
        self.path = path
        self.reason = reason
        self.evidence = evidence
    }
}

/// What a removal review offers: the app and what was found with it.
public struct AppRemovalPlan: Sendable {
    public let app: InstalledApp
    /// The bundle first, then launch agents, then the rest by location.
    public let items: [LeftoverItem]
    /// Found, but needing an administrator or the vendor's uninstaller.
    public let protected: [ProtectedLeftover]
    /// Why the bundle itself can't be moved from this account; nil when it can.
    public let blocker: String?

    public init(app: InstalledApp, items: [LeftoverItem], protected: [ProtectedLeftover], blocker: String?) {
        self.app = app
        self.items = items
        self.protected = protected
        self.blocker = blocker
    }

    /// The items that start selected.
    public var preselected: Set<LeftoverItem.ID> {
        Set(items.filter(\.startsSelected).map(\.id))
    }
}

/// A process running from inside an app bundle.
public struct BundleProcess: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let uid: uid_t
    public let path: String

    public init(pid: Int32, uid: uid_t, path: String) {
        self.pid = pid
        self.uid = uid
        self.path = path
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Who has to stop the processes running from an app before it can go.
public struct RunningCheck: Sendable, Hashable {
    /// Yours, and not started by a launch agent that's about to be unloaded:
    /// these need quitting first.
    public var needQuitting: [BundleProcess] = []
    /// Started by one of the app's launch agents; unloading it stops them.
    public var stopWithAgent: [BundleProcess] = []
    /// Another user's, such as root's: stopping them needs an administrator.
    public var otherUsers: [BundleProcess] = []

    public init(needQuitting: [BundleProcess] = [], stopWithAgent: [BundleProcess] = [], otherUsers: [BundleProcess] = []) {
        self.needQuitting = needQuitting
        self.stopWithAgent = stopWithAgent
        self.otherUsers = otherUsers
    }

    /// Nothing stands in the way of moving the app.
    public var isClear: Bool { needQuitting.isEmpty && otherUsers.isEmpty }
    public var isEmpty: Bool { isClear && stopWithAgent.isEmpty }
}

/// The steps of a removal, in order (see `AppRemoval.trashOrder`).
public struct RemovalOrder: Sendable, Hashable {
    /// Launch agents to unload first.
    public let unload: [LaunchItem]
    /// The bundle, then any link to it.
    public let app: [LeftoverItem]
    /// Everything else, moved only once the app has.
    public let rest: [LeftoverItem]
}

/// What happened to one item.
public enum RemovalResult: Sendable, Hashable {
    /// In the Trash, at this path.
    case moved(to: String)
    case failed(String)
    /// Not tried, and why.
    case skipped(String)

    public var succeeded: Bool {
        if case .moved = self { return true }
        return false
    }
}

public struct RemovalOutcome: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let result: RemovalResult

    public init(path: String, result: RemovalResult) {
        self.path = path
        self.result = result
    }
}
