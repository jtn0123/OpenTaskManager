import Foundation

/// Where an item was found, separately from the domain where its job runs.
public enum LaunchItemSource: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case userAgents, sharedAgents, daemons, macOS, bundledAgent, bundledDaemon, loginItem, loadedWithoutFile

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userAgents: "Your LaunchAgents folder"
        case .sharedAgents: "Shared LaunchAgents"
        case .daemons: "LaunchDaemons"
        case .macOS: "macOS"
        case .bundledAgent: "App-bundled agent"
        case .bundledDaemon: "App-bundled daemon"
        case .loginItem: "App login item"
        case .loadedWithoutFile: "Loaded, no file found"
        }
    }

    public var isAppBundled: Bool { [.bundledAgent, .bundledDaemon, .loginItem].contains(self) }

    /// Both the stable JSON name and the visible title work in the CLI and screenshots.
    public init?(name: String) {
        guard let source = Self.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame || $0.title.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = source
    }

    static func folder(path: String, scope: LaunchItemScope) -> Self {
        if path.hasPrefix("/System/") { return .macOS }
        switch scope {
        case .userAgent: return .userAgents
        case .systemAgent: return .sharedAgents
        case .daemon: return .daemons
        }
    }
}

public extension LaunchItem {
    var hasFile: Bool { source != .loadedWithoutFile }
    var hasPlist: Bool { hasFile && source != .loginItem }

    /// A helper shipped in an app is only known to be registered when launchd lists it.
    var startsAtLogin: Bool { scope.isAgent && startsAutomatically }

    var sourceDescription: String {
        if source.isAppBundled, let appBundlePath {
            return "Inside \((appBundlePath as NSString).lastPathComponent) · registered with macOS by the app"
        }
        return source.title
    }
}
