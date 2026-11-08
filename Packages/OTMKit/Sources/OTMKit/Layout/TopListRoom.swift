import Foundation

/// The rows of a "top apps" list (Top CPU, Top GPU, ...) and the room its
/// card keeps for them.
///
/// Only entries whose figure reads as something get a row: one that rounds to
/// "0.0%" would only fill the list with zeros. Below the rows a line says the
/// rest are idle, so the line counts as a row of room while it shows, though
/// it may be shorter than one (`height`). As apps go idle and busy the rows
/// come and go from one update to the next, so the card keeps room for the
/// most rows the list showed over the last `hold` seconds: it shrinks only
/// once fewer have been enough for a while, and the page under it doesn't
/// jump every tick. It grows only for rows that last: an entry busy for one
/// update alone, past the room kept, is left out, so the card never keeps
/// room for a row it didn't show.
public struct TopListRoom: Equatable, Sendable {
    private struct Need: Equatable, Sendable {
        let time: TimeInterval
        /// Rows the update's entries needed.
        let rows: Int
        /// Rows it needed that the update before needed too: what the room holds.
        let lasting: Int
    }

    /// Rows the list never goes past.
    public let limit: Int
    /// Seconds a smaller list must last before the room shrinks to it.
    public let hold: TimeInterval
    /// Rows of room now, idle line included.
    public private(set) var rows = 0
    /// Entries the list shows after the last update.
    public private(set) var shown = 0
    /// Each recent update's needs, oldest first, within `hold`.
    private var recent: [Need] = []

    public init(limit: Int, hold: TimeInterval = 30) {
        self.limit = max(limit, 1)
        self.hold = max(hold, 0)
    }

    /// How many of `figures`, the list's candidates busiest first as they'd
    /// be displayed, get a row: up to `limit`, stopping at the first that
    /// reads the same as a zero does (`zero`, "0.0%"). The figures are
    /// formatted on demand, so only the rows shown and one more are.
    public static func listed(_ figures: some Sequence<String>, zero: String, limit: Int) -> Int {
        var count = 0
        for figure in figures {
            guard count < limit, figure != zero else { break }
            count += 1
        }
        return count
    }

    /// Rows a list of `listed` entries takes: the entries, and the idle line
    /// under them while there's room left for it.
    public static func needed(listed: Int, limit: Int) -> Int {
        listed >= limit ? limit : max(listed, 0) + 1
    }

    /// Entries `rows` of room hold: a full list, or the rows over the idle line.
    public static func entries(rows: Int, limit: Int) -> Int {
        rows >= limit ? limit : max(rows - 1, 0)
    }

    /// How tall `rows` of room are, as `update` gives them: a full list's
    /// rows, or the entries before the idle line and the line, which is
    /// `idleLine` tall, each `spacing` apart. So a sparse list takes its rows
    /// and a short footer, not a row's room for the footer.
    public static func height(rows: Int, limit: Int, row: Double, idleLine: Double, spacing: Double) -> Double {
        if rows >= limit {
            return Double(limit) * row + Double(max(limit - 1, 0)) * spacing
        }
        let listed = max(rows - 1, 0)
        return Double(listed) * (row + spacing) + idleLine
    }

    /// Updates the room for an update whose figures list `listed` entries,
    /// taken at `time` in seconds, and gives how many of them to show.
    ///
    /// The room is the most rows two updates in a row needed within `hold`
    /// (the first update counts at once), so a row that shows for a moment
    /// doesn't hold room for the next 30 s. Entries past the room an update
    /// needs alone aren't shown, the least busy first. A repeat for the same
    /// `time`, the same sample drawn again, revises that update rather than
    /// counting as the next.
    @discardableResult
    public mutating func update(listed: Int, at time: TimeInterval) -> Int {
        let listed = min(max(listed, 0), limit)
        let needed = Self.needed(listed: listed, limit: limit)
        if recent.last?.time == time { recent.removeLast() }
        // A clock that went back starts over rather than holding room for the future.
        recent.removeAll { time - $0.time >= hold || $0.time > time }
        let lasting = min(needed, recent.last?.rows ?? needed)
        recent.append(Need(time: time, rows: needed, lasting: lasting))
        rows = recent.map(\.lasting).max() ?? lasting
        shown = min(listed, Self.entries(rows: rows, limit: limit))
        return shown
    }
}
