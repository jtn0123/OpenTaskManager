@testable import OTMKit
import Testing

struct StripRowsTests {
    @Test func oneRowSharesOutTheRoomLeft() {
        let rows = GridMath.stripRows(widths: [100, 50, 70], width: 270, spacing: 10)
        #expect(rows == [GridMath.StripRow(items: 0..<3, widths: [110, 60, 80])])
        #expect(GridMath.stripRows(widths: [], width: 260, spacing: 10).isEmpty)
    }

    @Test func wrappedRowsLineUpInEvenColumns() {
        // Connections' six chips at 820 points: too wide for one row, so two
        // rows of three columns, each as wide as a third of the strip.
        let widths: [Double] = [104, 98, 220, 122, 106, 188]
        let rows = GridMath.stripRows(widths: widths, width: 788, spacing: 8)
        #expect(rows.map(\.items) == [0..<3, 3..<6])
        let column = (788 - 2 * 8) / 3.0
        for row in rows {
            #expect(row.widths == [column, column, column])
        }
        #expect(column >= widths.max() ?? 0)
    }

    @Test func aShortLastRowKeepsTheColumnWidth() {
        // Five chips that fit three across: rows of three and two, the two
        // as wide as the columns above them, not stretched across the row.
        let rows = GridMath.stripRows(widths: [90, 90, 90, 90, 90], width: 300, spacing: 10)
        #expect(rows.map(\.items) == [0..<3, 3..<5])
        let column = (300 - 2 * 10) / 3.0
        #expect(rows[1].widths == [column, column])
    }

    @Test func aChipWiderThanTheStripTakesItsWidth() {
        let rows = GridMath.stripRows(widths: [80, 400, 80], width: 300, spacing: 10)
        #expect(rows.map(\.items) == [0..<1, 1..<2, 2..<3])
        #expect(rows.allSatisfy { $0.widths == [300] })
    }
}
