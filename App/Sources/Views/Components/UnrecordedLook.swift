import AppKit

/// How a graph shows a stretch with nothing recorded, in one place for the
/// live graphs (`StreamGraphView`: Performance, Overview, the process
/// inspector) and the History page's gaps (`HistoryGapStyle`): a light
/// neutral wash over the plot's tint and a faint diagonal hatch, enough to
/// tell it from a recorded quiet stretch (never drawn as zero) without
/// outweighing the data beside it, and a firmer dashed edge where recording
/// starts.
enum UnrecordedLook {
    /// Horizontal distance between the hatch's diagonals.
    static let hatchSpacing: CGFloat = 10
    static let hatchWidth: CGFloat = 0.75

    /// The window background's opacity over the plot.
    static func washOpacity(dark: Bool) -> CGFloat { dark ? 0.22 : 0.35 }
    /// The label colour's opacity in the hatch: a texture that says "nothing
    /// here", fainter than the grid's lines, while the wash and the edge
    /// mark the stretch out.
    static func hatchOpacity(dark: Bool) -> CGFloat { dark ? 0.035 : 0.03 }
    /// The label colour's opacity in the edge where recording starts.
    static func edgeOpacity(dark: Bool) -> CGFloat { dark ? 0.35 : 0.4 }
}
