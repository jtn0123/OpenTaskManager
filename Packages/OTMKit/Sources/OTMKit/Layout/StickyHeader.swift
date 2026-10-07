import Foundation

/// Where a table's heading goes while the page it sits in scrolls: at the
/// table's top while that's in view, then level with the top of the visible
/// area as the rows scroll under it, until the table's end pushes it up and
/// out with the last rows.
public enum StickyHeader {
    /// The heading's top in the table's own coordinates, y down.
    /// `visibleTop` is where the visible area starts in those coordinates:
    /// negative or zero while the table's top is in view.
    public static func offset(visibleTop: Double, tableHeight: Double, headerHeight: Double) -> Double {
        guard visibleTop.isFinite else { return 0 }
        return max(min(visibleTop, tableHeight - headerHeight), 0)
    }
}
