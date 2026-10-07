import OTMKit
import SwiftUI

/// Cards in rows that always span the full width. As many columns fit as
/// `minimum` allows, the cards spread evenly over the rows, and each card is
/// offered its row's full height, so a missing card (no GPU, no power
/// sensors) never leaves a hole and neighbours line up at the bottom.
struct FillGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 16
    /// Off, each card keeps its own height, top-aligned in its row, for
    /// cards whose length varies a lot (the System page's attached devices).
    var evensHeights = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimum + spacing) * CGFloat(subviews.count) - spacing
        let heights = rows(subviews: subviews, width: width)
        return CGSize(width: width, height: heights.map(\.height).reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let height = evensHeights ? row.height : nil
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: row.itemWidth, height: height))
                x += row.itemWidth + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: Range<Int>
        var itemWidth: CGFloat
        var height: CGFloat
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        GridMath.rows(count: subviews.count, width: width, minimum: minimum, spacing: spacing).map { items in
            let itemWidth = GridMath.itemWidth(items: items.count, width: width, spacing: spacing)
            let height = items.map { subviews[$0].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            return Row(items: items, itemWidth: itemWidth, height: height)
        }
    }
}
