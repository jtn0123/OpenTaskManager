import Foundation

/// How the CPU page lays out one graph tile per logical CPU over the area
/// its main graph fills: as few empty cells as there can be, tiles about
/// as wide as they're tall, and rows that don't mix core types where that costs
/// nothing, so 18 cores in a wide pane are 6 by 3 big tiles, never a row of
/// strips. Worked out only when the area or the cores change, never per tick.
public struct CoreAreaGrid: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    /// Cells left empty after the last tile.
    public func emptyCells(count: Int) -> Int {
        columns * rows - max(count, 0)
    }

    /// The width over the height a tile wants: square, so a grid of them
    /// reads as tiles rather than as strips either way.
    public static let preferredAspect = 1.0
    /// Tiles narrower or wider than this, width over height, are only taken
    /// when nothing else fits: a tall strip or a flat ribbon hides the graph.
    public static let usableAspects = 0.5...3.2

    /// The grid for `count` tiles over `width` by `height` points, `spacing`
    /// apart. `groups` are the tiles' runs by core type, in order (12
    /// Performance then 6 Efficiency cores is `[12, 6]`): columns that start
    /// each type on a fresh row count as a shape up to `alignmentBonus`
    /// nearer square, so they win over a slightly better shape, never over
    /// tall strips.
    public static func best(count: Int, width: Double, height: Double, spacing: Double = 6, groups: [Int] = []) -> CoreAreaGrid {
        guard count > 1, width > 0, height > 0 else { return CoreAreaGrid(columns: max(count, 1), rows: 1) }
        var best: (layout: CoreAreaGrid, score: Score)?
        for columns in 1...count {
            let layout = CoreAreaGrid(columns: columns, rows: (count + columns - 1) / columns)
            let tile = layout.tileSize(width: width, height: height, spacing: spacing)
            guard tile.width > 0, tile.height > 0 else { continue }
            let aspect = tile.width / tile.height
            let aligned = !groups.isEmpty && groups.allSatisfy { $0 % columns == 0 }
            let score = Score(
                usable: usableAspects.contains(aspect),
                empty: layout.emptyCells(count: count),
                misfit: abs(log(aspect / preferredAspect)) - (aligned ? alignmentBonus : 0)
            )
            if best.map({ score.beats($0.score) }) ?? true { best = (layout, score) }
        }
        return best?.layout ?? CoreAreaGrid(columns: count, rows: 1)
    }

    /// One tile's size over `width` by `height`.
    public func tileSize(width: Double, height: Double, spacing: Double = 6) -> (width: Double, height: Double) {
        ((width - Double(columns - 1) * spacing) / Double(columns), (height - Double(rows - 1) * spacing) / Double(rows))
    }

    /// The height the grid needs so no tile is shorter than `minimumTile`,
    /// or `height` when that's already enough.
    public func height(atLeast height: Double, minimumTile: Double, spacing: Double = 6) -> Double {
        max(height, Double(rows) * minimumTile + Double(rows - 1) * spacing)
    }

    /// How much nearer square, as a log of the aspect, a grid whose rows keep
    /// core types apart counts as being: about 1.4 times.
    public static let alignmentBonus = 0.35

    /// How one arrangement compares with another: a usable shape first, then
    /// fewer empty cells, then the shape nearer the preferred one, rows that
    /// keep core types apart counting as nearer.
    private struct Score {
        var usable: Bool
        var empty: Int
        var misfit: Double

        func beats(_ other: Score) -> Bool {
            if usable != other.usable { return usable }
            guard usable else { return misfit < other.misfit }
            if empty != other.empty { return empty < other.empty }
            return misfit < other.misfit
        }
    }
}
