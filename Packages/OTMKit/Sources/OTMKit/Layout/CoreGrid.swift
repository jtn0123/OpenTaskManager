import Foundation

/// How the Overview lays out a small graph for every logical CPU, grouped by
/// core type: one width for every tile, so the graphs compare at a glance
/// and the columns line up from one group to the next.
///
/// Groups that all fit on one line sit side by side (four performance and
/// four efficiency cores in a wide window). Otherwise each group takes rows
/// of its own, in as many columns as fit, with its tiles spread evenly over
/// its rows (twelve cores that fit nine across make two rows of six, not
/// nine and three), and every group keeps the widest group's column count.
public struct CoreGrid: Equatable, Sendable {
    /// Tiles across a row: the widest group's row when the groups take rows
    /// of their own, every tile when they share one.
    public var columns: Int
    /// Whether the groups sit side by side on one line.
    public var sharesRow: Bool
    /// Each tile's width.
    public var tileWidth: Double

    /// The grid for groups of `counts` tiles in a container `width` wide,
    /// each tile at least `minimum` wide (unless the container is narrower),
    /// `spacing` apart within a group and `groupSpacing` apart between
    /// groups side by side.
    public init(counts: [Int], width: Double, minimum: Double, spacing: Double, groupSpacing: Double) {
        let counts = counts.filter { $0 > 0 }
        let width = width.isFinite ? max(width, 0) : 0
        let total = counts.reduce(0, +)
        guard total > 0 else {
            self.init(columns: 1, sharesRow: false, tileWidth: width)
            return
        }
        // Side by side, the gaps within groups and the wider ones between them.
        let gaps = spacing * Double(total - counts.count) + groupSpacing * Double(counts.count - 1)
        if counts.count > 1, Double(total) * minimum + gaps <= width + 1e-9 {
            self.init(columns: total, sharesRow: true, tileWidth: (width - gaps) / Double(total))
            return
        }
        let fitting = GridMath.columnCount(count: Int.max, width: width, minimum: minimum, spacing: spacing)
        let columns = counts.map { count in
            let rows = (count + fitting - 1) / fitting
            return (count + rows - 1) / rows
        }.max() ?? 1
        self.init(columns: columns, sharesRow: false, tileWidth: GridMath.itemWidth(items: columns, width: width, spacing: spacing))
    }

    public init(columns: Int, sharesRow: Bool, tileWidth: Double) {
        self.columns = max(columns, 1)
        self.sharesRow = sharesRow
        self.tileWidth = tileWidth
    }

    /// A group of `count` tiles split into rows: one row when the groups
    /// share a line, otherwise as few rows of `columns` as hold them, with
    /// the tiles spread evenly over them (seven in rows of six go four and
    /// three, not six and one).
    public func rows(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        guard !sharesRow else { return [0..<count] }
        let rowCount = (count + columns - 1) / columns
        let perRow = (count + rowCount - 1) / rowCount
        return stride(from: 0, to: count, by: perRow).map { $0..<min($0 + perRow, count) }
    }
}
