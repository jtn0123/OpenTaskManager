import CoreGraphics
import Foundation

/// Which labels a treemap tile has room for, and where the hover tag for a
/// tile goes. The app measures the text; the decisions are here so they can
/// be tested. A label that doesn't fit is left out rather than cut down,
/// since "Ap…ns" names nothing; hovering shows the full name instead.
public enum TreemapLabel {
    /// Ordered: more shows more.
    public enum Fit: Sendable, Equatable, Comparable {
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

    /// A plain tile whose name has a shorter form (see `shortName`): the
    /// short one when it lets more show, else the whole one. `short` says
    /// which to draw.
    public static func tile(name: Double, shortName: Double?, size: Double, lineHeight: Double,
                            room: CGSize) -> (fit: Fit, short: Bool) {
        let whole = tile(name: name, size: size, lineHeight: lineHeight, room: room)
        guard whole != .nameAndSize, let shortName else { return (whole, false) }
        let short = tile(name: shortName, size: size, lineHeight: lineHeight, room: room)
        return short > whole ? (short, true) : (whole, false)
    }

    /// A file's name without its extension ("Holiday-2026" for
    /// "Holiday-2026.mov"), to try when the whole name doesn't fit. Still
    /// a whole name rather than a cut one. Nil when there's nothing to drop.
    public static func shortName(_ name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty || stem == name ? nil : stem
    }

    /// Where a tag of `size` goes for `tile` in a treemap of `bounds`: under
    /// the tile if it fits there, else above it, so the tile itself stays in
    /// view; for a tile as tall as the treemap, inside its top-left corner.
    /// It never pokes out of the treemap, and it keeps clear of `heading`,
    /// the name strip of the folder tile holding `tile` (or of `tile`
    /// itself): rather than above a tile at the top of its folder it goes
    /// above the folder's name, and inside, under it.
    public static func tagOrigin(size: CGSize, tile: CGRect, bounds: CGSize, heading: CGRect? = nil, gap: CGFloat = 6) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, 0), max(bounds.width - size.width, 0)) }
        let x = clampX(tile.minX)
        func clear(_ y: CGFloat) -> Bool {
            heading.map { !CGRect(x: x, y: y, width: size.width, height: size.height).intersects($0) } ?? true
        }
        let below = tile.maxY + gap
        if below + size.height <= bounds.height, clear(below) { return CGPoint(x: x, y: below) }
        let above = tile.minY - gap - size.height
        if above >= 0, clear(above) { return CGPoint(x: x, y: above) }
        if let heading {
            let overHeading = heading.minY - gap - size.height
            if overHeading >= 0 { return CGPoint(x: x, y: overHeading) }
        }
        let top = max(tile.minY, heading.map { $0.maxY } ?? tile.minY) + gap
        let inside = min(max(top, 0), max(bounds.height - size.height, 0))
        return CGPoint(x: clampX(tile.minX + gap), y: inside)
    }
}
