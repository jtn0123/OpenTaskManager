import Foundation

/// Compare's wording: the Change column names its direction, so a plus
/// always means A is higher; the narrow card says less and keeps the rest
/// in tooltips.
public enum HistoryCompareLabels {
    public static let changeHeading = "Change, A vs B"
    public static let changeAccessibility = "Change, A compared with B"
    public static let compactFigures = "Disk/network combined; gaps excluded."
    public static let compactSelection = "Drag to pick A; drag again for B."
    public static let changeHelp = "How A differs from B: in percentage points for a share, in degrees for a temperature, "
        + "else relative to B (×12 is twelve times B). A plus means A is higher."
    public static let figuresHelp = "Disk and network add both directions. Gaps are left out of every figure."
    public static let overlapHelp = "A and B are narrowed to the stretch both recorded at the same offsets from their starts."
    public static let limitationHelp = "Each side's figures cover its recorded time alone, so a change may come from what wasn't recorded."
    public static let selectionHelp = "Drag along the timeline to pick A, the stretch to look at. It's compared with the same length "
        + "just before it, or drag again to pick B."

    public static func detailsTitle(expanded: Bool, compact: Bool) -> String {
        if compact { return expanded ? "Less" : "More" }
        return expanded ? "Fewer Figures" : "All Figures"
    }

    public static func coverage(_ coverage: Double, compact: Bool) -> String {
        guard compact else { return HistoryInterval.recorded(coverage) }
        guard coverage.isFinite, coverage > 0 else { return "0%" }
        return coverage < 0.005 ? "<1%" : Format.percent(min(coverage, 1))
    }

    public static func notice(_ limitation: HistoryComparison.Limitation) -> String {
        let sides = limitation.sides.map(\.rawValue).joined(separator: " and ")
        let reason = limitation.kind == .low ? "Little recorded in \(sides)" : "Less recorded in \(sides)"
        return reason + "; changes may reflect gaps."
    }
}
