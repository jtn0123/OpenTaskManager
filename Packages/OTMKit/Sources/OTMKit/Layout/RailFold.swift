import Foundation

/// The History page's timeline card, pinned over the charts as they scroll:
/// whole while the page is near its top, folded to a strip once the charts'
/// top has scrolled out of view, and whole again once the page is back where
/// the card sits unpinned. Between those two lines it stays as it was, so
/// the strip's lower height, which moves the charts up under it, never flips
/// it back. Opened from the strip, it stays open until the page is back at
/// the top or it's folded again. Everything here moves only on scroll.
public struct RailFold: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// The whole card, near the top of the page.
        case whole
        /// The strip, scrolled down among the charts.
        case folded
        /// The whole card, opened from the strip while scrolled down.
        case opened
    }

    public private(set) var state = State.whole

    public init() {}

    public var isFolded: Bool { state == .folded }

    /// The page scrolled. `visibleTop` is the top of what shows, `railTop`
    /// where the card sits unpinned (it pins once the page scrolls past
    /// that) and `chartsTop` where the charts begin below the whole card,
    /// all in the page's coordinates, y down.
    public mutating func scrolled(visibleTop: Double, railTop: Double, chartsTop: Double) {
        guard visibleTop.isFinite, railTop.isFinite, chartsTop.isFinite else { return }
        if visibleTop <= railTop {
            state = .whole
        } else if state == .whole, visibleTop >= max(chartsTop, railTop) {
            state = .folded
        }
    }

    /// The strip's expand control: the whole card, until the page is back
    /// at the top or it's folded again.
    public mutating func open() {
        if state == .folded { state = .opened }
    }

    /// Folds a card opened from the strip again.
    public mutating func fold() {
        if state == .opened { state = .folded }
    }
}
