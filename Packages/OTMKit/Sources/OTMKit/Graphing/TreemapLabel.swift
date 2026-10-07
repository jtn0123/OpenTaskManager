import CoreGraphics
import Foundation

/// Which labels a treemap tile has room for, and where the hover tag for a
/// tile goes. The app measures the text; the decisions are here so they can
/// be tested. A label that doesn't fit is left out rather than cut down,
/// since "Ap…ns" names nothing; hovering shows the full name instead.
public enum TreemapLabel {
    public enum Fit: Sendable, Equatable {
        case none
        case name
        case nameAndSize
    }

    /// A folder's header strip: the name, then the size beside it. When room
    /// is short the size is dropped first; without room for the whole name,
    /// nothing shows.
    public static func header(name: Double, size: Double, spacing: Double, room: Double) -> Fit {
        if name + spacing + size <= room { return .nameAndSize }
        return name <= room ? .name : .none
    }

    /// A plain tile: the name, with the size on a line under it.
    public static func tile(name: Double, size: Double, lineHeight: Double, room: CGSize) -> Fit {
        guard name <= Double(room.width), lineHeight <= Double(room.height) else { return .none }
        return size <= Double(room.width) && 2 * lineHeight <= Double(room.height) ? .nameAndSize : .name
    }

    /// Where a tag of `size` goes for `tile` in a treemap of `bounds`: under
    /// the tile if it fits there, else above it, so the tile itself stays in
    /// view; for a tile as tall as the treemap, inside its top-left corner.
    /// It never pokes out of the treemap.
    public static func tagOrigin(size: CGSize, tile: CGRect, bounds: CGSize, gap: CGFloat = 6) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, 0), max(bounds.width - size.width, 0)) }
        let below = tile.maxY + gap
        if below + size.height <= bounds.height { return CGPoint(x: clampX(tile.minX), y: below) }
        let above = tile.minY - gap - size.height
        if above >= 0 { return CGPoint(x: clampX(tile.minX), y: above) }
        let inside = min(max(tile.minY + gap, 0), max(bounds.height - size.height, 0))
        return CGPoint(x: clampX(tile.minX + gap), y: inside)
    }
}
