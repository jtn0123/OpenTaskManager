import OTMKit
import SwiftUI

/// Cards in rows that always span the full width. As many columns fit as
/// `minimum` allows, the cards spread evenly over the rows, and each card is
/// offered its row's full height, so a missing card (no GPU, no power
/// sensors) never leaves a hole and neighbours line up at the bottom.
struct FillGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 16

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
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: row.itemWidth, height: row.height))
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

/// Cards in columns that each run their own length, as many as `minimum`
/// allows (one in a narrow window). In order, each card goes under the
/// column that's shortest so far, so a short card beside a long one leaves
/// no hole: not inside it, as `FillGrid`'s even rows would, nor below it.
/// For pages of cards whose lengths differ a lot (System).
struct ColumnGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimum + spacing) * CGFloat(subviews.count) - spacing
        return CGSize(width: width, height: packing(subviews: subviews, width: width).packing.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (packing, itemWidth) = packing(subviews: subviews, width: bounds.width)
        for index in subviews.indices {
            let x = bounds.minX + CGFloat(packing.columns[index]) * (itemWidth + spacing)
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + packing.tops[index]),
                                  proposal: ProposedViewSize(width: itemWidth, height: nil))
        }
    }

    private func packing(subviews: Subviews, width: CGFloat) -> (packing: GridMath.ColumnPacking, itemWidth: CGFloat) {
        let columns = GridMath.columnCount(count: subviews.count, width: width, minimum: minimum, spacing: spacing)
        let itemWidth = GridMath.itemWidth(items: columns, width: width, spacing: spacing)
        let heights = subviews.map { Double($0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height) }
        return (GridMath.packColumns(heights: heights, columns: columns, spacing: spacing), itemWidth)
    }
}
