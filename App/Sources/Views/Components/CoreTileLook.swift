import AppKit
import SwiftUI

/// The look every per-core graph tile shares: the Overview's small ones
/// (`CoreGraphsCard`) and the CPU page's big ones (`CoreGraphGrid`), so they
/// read as one family at two sizes. A line of labels over the graph, the
/// CPU's number and its load now, in a wash and border of its core type's
/// colour that firm up with the load; the load takes that colour once the
/// core is more than half busy.
enum CoreTileLook {
    static let cornerRadius: CGFloat = 5
    /// The labels' line over the graph.
    static let labelHeight: CGFloat = 17
    /// The labels' inset from the tile's sides.
    static let labelInset: CGFloat = 6
    /// The metadata size, 12 pt, so a small tile keeps its room for the graph.
    static let labelSize: CGFloat = 12
    static var labelFont: Font { .system(size: labelSize, weight: .medium).monospacedDigit() }
    @MainActor static let labelNSFont = NSFont.monospacedDigitSystemFont(ofSize: labelSize, weight: .medium)
    static let lineWidth: CGFloat = 1.2
    /// From this load on, the reading takes the core type's colour.
    static let hotLoad = 0.5

    /// The wash's opacity at the top of the tile for a load of 0 to 1. It
    /// fades to `washFoot` at the bottom.
    static func washTop(_ load: Double) -> Double {
        0.06 + 0.22 * clamped(load)
    }

    static let washFoot = 0.02

    /// The border's opacity for a load of 0 to 1.
    static func border(_ load: Double) -> Double {
        0.18 + 0.5 * clamped(load)
    }

    /// Whether the reading takes the core type's colour.
    static func isHot(_ load: Double) -> Bool {
        load > hotLoad
    }

    private static func clamped(_ load: Double) -> Double {
        load.isFinite ? min(max(load, 0), 1) : 0
    }
}
