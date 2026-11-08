import Foundation

/// Keeps the CPU's summary in reach without replacing any core graph.
/// The larger choice fills the old area; the default caps each whole tile,
/// including its labels. More height is used only when the pane has spare room.
public struct CoreGraphLayout: Sendable, Equatable {
    public var grid: CoreAreaGrid
    public var height: Double

    public init(count: Int, width: Double, availableHeight: Double, larger: Bool, spacing: Double = 6, groups: [Int] = []) {
        let available = availableHeight.isFinite && availableHeight > 0 ? availableHeight : 260
        let width = width.isFinite && width > 0 ? width : 600
        // Hero's area reserves only the first row of figures. Keep room for
        // the remaining rows and the extra control, especially in narrow panes.
        let area = larger ? available : max(available - 100, 192)
        grid = CoreAreaGrid.best(count: count, width: width, height: area, spacing: spacing, groups: groups)
        let maximumTile = min(130 + max(available - 500, 0) / 4, 180)
        let capped = Double(grid.rows) * maximumTile + Double(grid.rows - 1) * spacing
        height = grid.height(atLeast: larger ? available : min(area, capped), minimumTile: 64, spacing: spacing)
    }
}
