/// Stable names for the window's pages, also used by saved settings and launch arguments.
public enum Page: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case processes = "Processes"
    case performance = "Performance"
    case history = "History"
    case connections = "Connections"
    case startup = "Startup"
    case apps = "Apps"
    case users = "Users"
    case system = "System"
    case drivers = "Drivers"
    case storage = "Storage"

    public var id: String { rawValue }

    /// An invalid explicit name opens Overview rather than falling through to a saved page.
    public static func starting(openPage: String?, savedPage: String?) -> Self {
        (openPage ?? savedPage).flatMap(Self.init(rawValue:)) ?? .overview
    }

    /// The View menu gives the first nine pages number shortcuts in their sidebar order.
    public var shortcutNumber: Int? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return index + 1
    }
}
