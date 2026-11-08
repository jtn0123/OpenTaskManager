import OTMKit
import SwiftUI

/// Items in rows, in order, each at its own width. As few rows are used as
/// fit, the items spread evenly over them, and the room left in a row is
/// shared out between its items, so a strip of readings stays on one line
/// while it fits and wraps into tidy rows when it doesn't.
struct FlowRow: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 10
    /// Off, a row's items keep their own widths from the leading edge, as a
    /// row of buttons does.
    var spreads = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = subviews.map { Double($0.sizeThatFits(.unspecified).width) }
        let width = proposal.width ?? CGFloat(widths.reduce(0, +)) + spacing * CGFloat(max(widths.count - 1, 0))
        let heights = rows(widths: widths, width: width).map { row in
            row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
        }
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { Double($0.sizeThatFits(.unspecified).width) }
        var y = bounds.minY
        for row in rows(widths: widths, width: bounds.width) {
            let spread = spreads ? GridMath.spread(row.map { widths[$0] }, across: Double(bounds.width), spacing: Double(spacing))
                : row.map { widths[$0] }
            var x = bounds.minX
            var height: CGFloat = 0
            for (index, width) in zip(row, spread) {
                // An item too wide for any row is held to the width and truncates.
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                height = max(height, size.height)
                x += CGFloat(width) + spacing
            }
            y += height + lineSpacing
        }
    }

    private func rows(widths: [Double], width: CGFloat) -> [Range<Int>] {
        GridMath.flowRows(widths: widths, width: Double(width), spacing: Double(spacing))
    }
}
