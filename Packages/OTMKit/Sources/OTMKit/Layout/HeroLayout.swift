import Foundation

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

/// A main graph's fine grid: how far apart its rows are, and how many
/// samples apart its columns, about as far apart as the rows and never
/// closer than `minimum` points. Columns belong to sample times, so they
/// scroll with the data, as every live graph's do.
public enum FineGridSpacing {
    /// Points between the rows that split a plot `height` tall, less `inset`
    /// at each end, into `rows`; 0 where there's no room for them.
    public static func row(height: Double, inset: Double, rows: Int) -> Double {
        let usable = height - 2 * inset
        guard rows > 0, usable.isFinite, usable > 4 else { return 0 }
        return usable / Double(rows)
    }

    /// Samples between columns, for samples `sampleStep` points apart.
    public static func columnSamples(rowStep: Double, sampleStep: Double, minimum: Double = 12) -> Int {
        guard sampleStep.isFinite, sampleStep > 0 else { return 1 }
        let target = rowStep.isFinite ? max(rowStep, minimum) : minimum
        return max(Int((target / sampleStep).rounded()), Int((minimum / sampleStep).rounded(.up)), 1)
    }
}
