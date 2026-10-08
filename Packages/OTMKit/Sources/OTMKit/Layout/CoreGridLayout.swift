import Foundation

/// How the CPU page lays out one graph tile per logical CPU over the area
/// its main graph fills: as few empty cells as there can be, tiles about
/// as wide as they're tall, and rows that don't mix core types where that costs
/// nothing, so 18 cores in a wide pane are 6 by 3 big tiles, never a row of
/// strips. Worked out only when the area or the cores change, never per tick.
public struct CoreGridLayout: Equatable, Sendable {
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
    public static func best(count: Int, width: Double, height: Double, spacing: Double = 6, groups: [Int] = []) -> CoreGridLayout {
        guard count > 1, width > 0, height > 0 else { return CoreGridLayout(columns: max(count, 1), rows: 1) }
        var best: (layout: CoreGridLayout, score: Score)?
        for columns in 1...count {
            let layout = CoreGridLayout(columns: columns, rows: (count + columns - 1) / columns)
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
        return best?.layout ?? CoreGridLayout(columns: count, rows: 1)
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

/// The heights of Performance's main graphs: the visible height of the
/// detail pane less what has to show with the graph (the page's title and
/// level bar, the card's caption and time axis, and the first row of
/// figures under it), so the graph fills the pane without hiding them.
public enum HeroHeight {
    /// Shorter than this, a graph is no longer the page's main one: the pane
    /// scrolls instead.
    public static let minimum = 220.0
    /// Taller than this, a graph only spreads its line thinner.
    public static let maximum = 860.0

    /// The graph's height for a pane `visible` points tall, `reserved` of
    /// them for what shows around it.
    public static func graph(visible: Double, reserved: Double) -> Double {
        guard visible.isFinite, reserved.isFinite, visible > 0 else { return minimum }
        return min(max((visible - reserved).rounded(), minimum), maximum)
    }
}

/// The segments of a level bar: how many fit a width, and how many a
/// reading lights.
public enum LevelSegments {
    /// Segments this many points wide, `gap` apart, fill `width`; never fewer than 10.
    public static func count(width: Double, segment: Double = 5, gap: Double = 2.5) -> Int {
        guard width.isFinite, width > 0, segment > 0 else { return 10 }
        return max(Int((width + gap) / (segment + gap)), 10)
    }

    /// Segments lit for `fraction` of `count`: a reading above zero lights
    /// at least one, so a busy-but-light load isn't shown as none, and only
    /// a full reading lights them all.
    public static func lit(_ fraction: Double, of count: Int) -> Int {
        guard fraction.isFinite, fraction > 0, count > 0 else { return 0 }
        if fraction >= 1 { return count }
        return min(max(Int((fraction * Double(count)).rounded()), 1), count - 1)
    }
}

/// The columns of a grid of label-over-value figures: as many as fit
/// `width` at `minimum` points each, `spacing` apart, never more than there
/// are figures. Each keeps the width it would have in a full row, so a
/// short last row lines up under the one above.
public enum FigureColumns {
    /// The width a row of `count` figures asks for when nothing bounds it.
    public static func idealWidth(count: Int, minimum: Double, spacing: Double) -> Double {
        let count = max(count, 1)
        return Double(count) * minimum + Double(count - 1) * spacing
    }

    /// The columns and their width. An unbounded or unusable `width` (a
    /// layout's infinite or NaN proposal) is taken as the ideal one.
    public static func fit(width: Double, count: Int, minimum: Double, spacing: Double) -> (count: Int, width: Double) {
        let usable = width.isFinite && width >= 0 ? width : idealWidth(count: count, minimum: minimum, spacing: spacing)
        guard minimum + spacing > 0 else { return (max(count, 1), usable) }
        let fit = max(Int(((usable + spacing) / (minimum + spacing)).rounded(.down)), 1)
        return (min(fit, max(count, 1)), max((usable - Double(fit - 1) * spacing) / Double(fit), 0))
    }
}
