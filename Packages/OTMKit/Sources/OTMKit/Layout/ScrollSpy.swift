import Foundation

/// Which card is at the top of a page of cards as it scrolls, for a jump bar
/// that follows the scrolling. With cards in columns several cross the top at
/// once; the one whose top passed it last counts, so the bar names the card
/// that has just come up (the one a jump lands on) rather than the tail of a
/// long card beside it.
public enum ScrollSpy {
    /// A card's top and bottom in page coordinates, y down.
    public struct Card<ID>: Sendable where ID: Sendable {
        public let id: ID
        public let top: Double
        public let bottom: Double

        public init(_ id: ID, top: Double, bottom: Double) {
            self.id = id
            self.top = top
            self.bottom = bottom
        }
    }

    /// Of the cards still showing below `line` (the visible top plus a
    /// little), the one whose top is latest at or above it; before any card
    /// has reached it, the first of `cards` (in page order) still showing.
    public static func current<ID>(_ cards: [Card<ID>], line: Double) -> ID? {
        var first: ID?
        var latest: Card<ID>?
        for card in cards where card.bottom > line {
            if first == nil { first = card.id }
            if card.top <= line, card.top > latest?.top ?? -.infinity { latest = card }
        }
        return latest?.id ?? first
    }
}
