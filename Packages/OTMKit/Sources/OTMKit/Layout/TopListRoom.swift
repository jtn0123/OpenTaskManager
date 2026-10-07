import Foundation

/// The rows of a "top apps" list (Top CPU, Top GPU, ...) and the room its
/// card keeps for them.
///
/// Only entries whose figure reads as something get a row: one that rounds to
/// "0.0%" would only fill the list with zeros. Below the rows a line says the
/// rest are idle, so the line takes a row's room while it shows. As apps go
/// idle and busy the rows come and go from one sample to the next, so the
/// card keeps room for the most rows the list needed over the last `hold`
/// seconds: it grows at once but shrinks only once fewer have been enough
/// for a while, and the page under it doesn't jump every tick.
public struct TopListRoom: Equatable, Sendable {
    private struct Need: Equatable, Sendable {
        let time: TimeInterval
        let rows: Int
    }

    /// Rows the list never goes past.
    public let limit: Int
    /// Seconds a smaller list must last before the room shrinks to it.
    public let hold: TimeInterval
    /// Rows of room now, idle line included.
    public private(set) var rows = 0
    /// Rows needed at each recent update, oldest first, within `hold`.
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

    /// The room after an update that lists `listed` entries, at `time` in
    /// seconds on a steady clock: the most rows needed within `hold`.
    @discardableResult
    public mutating func update(listed: Int, at time: TimeInterval) -> Int {
        let needed = Self.needed(listed: min(listed, limit), limit: limit)
        recent.removeAll { time - $0.time >= hold }
        recent.append(Need(time: time, rows: needed))
        rows = recent.map(\.rows).max() ?? needed
        return rows
    }
}
