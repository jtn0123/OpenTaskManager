import AppKit
import OTMKit

/// How wide a table column's values and title are, in the fonts the table
/// draws them in, for `ContentColumnWidth`. Measured once per read of the
/// rows (a scan or Refresh), never per tick, each distinct value once.
@MainActor
enum ColumnContent {
    /// `.tableText`, the system's body size, which table rows use.
    private static let rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let headerFont = NSTableHeaderCell().font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// Beside a header's title: the sort arrow and the cell's insets on both sides.
    private static let headerChrome: CGFloat = 30

    /// The widest of `values` in the rows' font.
    static func width(of values: some Sequence<String>) -> CGFloat {
        Set(values).reduce(0) { widest, value in
            max(widest, ceil((value as NSString).size(withAttributes: [.font: rowFont]).width))
        }
    }

    /// What a header needs to show `title` whole with the sort arrow beside it.
    static func header(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: headerFont]).width) + headerChrome
    }

    /// A column's width for `values` under `title`, between `floor` and `cap`.
    static func fitting(_ values: some Sequence<String>, title: String, floor: CGFloat, cap: CGFloat? = nil,
                        extra: CGFloat = 0) -> CGFloat {
        let content = width(of: values)
        return CGFloat(ContentColumnWidth.fitting(content: Double(content > 0 ? content + extra : 0),
                                                  header: Double(header(title)), floor: Double(floor),
                                                  cap: cap.map(Double.init)))
    }
}

/// Widths measured for one read of a table's rows, kept until the next read,
/// for a page whose store, not the page, reads the rows: the body asks, and
/// measures again only for a new read, so a table starts at its widths.
@MainActor
final class ColumnWidthMemo<Widths> {
    private var readAt: Date?
    private var widths: Widths?

    func widths(readAt: Date?, measure: () -> Widths) -> Widths {
        if let widths, readAt == self.readAt { return widths }
        let measured = measure()
        self.readAt = readAt
        widths = measured
        return measured
    }
}
