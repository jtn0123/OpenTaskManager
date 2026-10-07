import AppKit

/// Process table column header with the whole-system total on its own line
/// above the column name, so a total like "23.3 MB/s" never squeezes the
/// name into "Disk 23.3 M…". Columns without a total leave the top line
/// empty, so every name sits on the same baseline.
final class ProcessHeaderCell: NSTableHeaderCell {
    /// Height of a header row with room for both lines.
    static let headerHeight: CGFloat = 38

    /// Whole-system figure shown above the name, or empty.
    var total = ""

    private static let totalFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let titleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let sortedTitleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    private static let inset: CGFloat = 5
    private static let bottomMargin: CGFloat = 5

    override func drawInterior(withFrame interiorFrame: NSRect, in controlView: NSView) {
        // AppKit passes a single centred text line; lay out both lines in the whole cell.
        let cellFrame = NSRect(x: interiorFrame.minX, y: controlView.bounds.minY,
                               width: interiorFrame.width, height: controlView.bounds.height)
        let sort = sortDirection(in: controlView)
        let titleFont = sort == nil ? Self.titleFont : Self.sortedTitleFont
        var titleFrame = titleLine(in: cellFrame, font: titleFont, flipped: controlView.isFlipped)
        if let ascending = sort {
            // The sort chevron shares the name's line; the total above uses the full width.
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
            let chevron = sortIndicatorRect(forBounds: cellFrame)
            if alignment == .right {
                titleFrame.size.width = max(chevron.minX - 2 - titleFrame.minX, 0)
            } else {
                titleFrame.size.width = min(titleFrame.width, max(chevron.minX - 2 - titleFrame.minX, 0))
            }
        }
        draw(stringValue, in: titleFrame, font: titleFont, color: .headerTextColor)

        guard !total.isEmpty else { return }
        var totalFrame = titleFrame
        totalFrame.size.width = cellFrame.width - 2 * Self.inset
        totalFrame.size.height = Self.totalFont.lineHeight
        totalFrame.origin.y += controlView.isFlipped ? -totalFrame.height : titleFrame.height
        draw(total, in: totalFrame, font: Self.totalFont, color: .labelColor)
    }

    override func sortIndicatorRect(forBounds rect: NSRect) -> NSRect {
        // Centre the chevron on the name's line rather than on the whole cell.
        var indicator = super.sortIndicatorRect(forBounds: rect)
        let line = titleLine(in: rect, font: Self.titleFont, flipped: controlView?.isFlipped ?? true)
        indicator.origin.y = line.midY - indicator.height / 2
        return indicator
    }

    private func titleLine(in cellFrame: NSRect, font: NSFont, flipped: Bool) -> NSRect {
        let height = font.lineHeight
        let y = flipped ? cellFrame.maxY - Self.bottomMargin - height : cellFrame.minY + Self.bottomMargin
        return NSRect(x: cellFrame.minX + Self.inset, y: y, width: cellFrame.width - 2 * Self.inset, height: height)
    }

    /// Whether the table is sorted by this column, and which way; nil if not.
    private func sortDirection(in controlView: NSView) -> Bool? {
        guard let tableView = (controlView as? NSTableHeaderView)?.tableView,
              let descriptor = tableView.sortDescriptors.first,
              tableView.tableColumns.contains(where: { $0.headerCell === self && $0.sortDescriptorPrototype?.key == descriptor.key })
        else { return nil }
        return descriptor.ascending
    }

    private func draw(_ text: String, in frame: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: frame, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

private extension NSFont {
    var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}
