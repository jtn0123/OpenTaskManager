import Foundation

/// How the Storage treemap shows an item picked in a list (a change, or a
/// large file): as a tile of its own, or only by the deepest tile it drew on
/// the way there, and why it couldn't draw the item itself. The app works
/// out which tiles it drew; the reasons are here so they can be tested.
public enum TreemapReach: Sendable, Equatable {
    /// A tile of its own.
    case drawn
    /// More levels below the open folder than the map draws, inside `holder`'s tile.
    case tooDeep(holder: Int)
    /// On a level the map draws, but too small for a tile at this size:
    /// inside `holder`'s, or with no tile on the way at all.
    case tooSmall(holder: Int?)
    /// Too small for the scan to keep on its own, so it's counted in
    /// `holder` (a folder's smaller items, or a folder whose contents
    /// weren't kept), or in something the map couldn't draw either.
    case notKept(holder: Int?)
    /// Gone since the earlier scan: `holder` is the tile drawn where it was.
    case removed(holder: Int?)

    /// Levels the map draws below the open folder: its children, and the
    /// children of a folder whose tile is big enough to show them.
    public static let levels = 2

    /// - Parameters:
    ///   - path: the items below the open folder down to the one that stands
    ///     for the pick (`DiskUsage.closestItem`), by ID.
    ///   - drawn: the deepest of them the map drew a tile for.
    ///   - exists: the pick is still there.
    ///   - isKept: the scan kept the pick as an item of its own.
    public static func of(path: [Int], drawn: Int?, exists: Bool, isKept: Bool) -> TreemapReach {
        guard exists else { return .removed(holder: drawn) }
        guard isKept else { return .notKept(holder: drawn) }
        guard let drawn else { return .tooSmall(holder: nil) }
        if drawn == path.last { return .drawn }
        return path.count > levels ? .tooDeep(holder: drawn) : .tooSmall(holder: drawn)
    }

    /// The tile outlined in the pick's place, when it isn't drawn itself.
    public var holder: Int? {
        switch self {
        case .drawn: nil
        case let .tooDeep(holder): holder
        case let .tooSmall(holder), let .notKept(holder), let .removed(holder): holder
        }
    }
}
