import Foundation

/// Where one item sits in a list as it's shown (filtered and sorted), and
/// its neighbours: for a details pane that covers the list, so Previous,
/// Next and "3 of 12" can step through it without going back.
public struct ListPosition<ID: Hashable>: Equatable {
    /// From 1.
    public let number: Int
    public let count: Int
    /// Nil at the top of the list.
    public let previous: ID?
    /// Nil at the bottom of the list.
    public let next: ID?

    /// Nil when the list doesn't hold `id`: a filter or search hides it, or
    /// it's gone. The first of any repeats counts.
    public init?(of id: ID, in ids: [ID]) {
        guard let index = ids.firstIndex(of: id) else { return nil }
        number = index + 1
        count = ids.count
        previous = index > 0 ? ids[index - 1] : nil
        next = index + 1 < ids.count ? ids[index + 1] : nil
    }
}
