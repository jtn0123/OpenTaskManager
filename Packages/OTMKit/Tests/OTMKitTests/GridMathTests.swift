@testable import OTMKit
import Testing

struct GridMathTests {
    @Test func fitsEverythingOnOneRowWhenThereIsRoom() {
        #expect(GridMath.rows(count: 4, width: 1000, minimum: 210, spacing: 16) == [0..<4])
    }

    @Test func missingCardStretchesTheRowInsteadOfLeavingAHole() {
        // Room for four, only three cards: one row of three, not three plus a gap.
        #expect(GridMath.rows(count: 3, width: 1000, minimum: 210, spacing: 16) == [0..<3])
    }

    @Test func balancesRowsWhenTheyWrap() {
        // Three fit across, four cards: two and two rather than three and one.
        #expect(GridMath.rows(count: 4, width: 700, minimum: 210, spacing: 16) == [0..<2, 2..<4])
        // Two fit across, five cards: rows of two, two and one.
        #expect(GridMath.rows(count: 5, width: 450, minimum: 210, spacing: 16) == [0..<2, 2..<4, 4..<5])
    }

    @Test func narrowContainerStacksOnePerRow() {
        #expect(GridMath.rows(count: 3, width: 100, minimum: 210, spacing: 16) == [0..<1, 1..<2, 2..<3])
    }

    @Test func unboundedWidthPutsEverythingOnOneRow() {
        #expect(GridMath.rows(count: 3, width: .infinity, minimum: 210, spacing: 16) == [0..<3])
    }

    @Test func emptyGridHasNoRows() {
        #expect(GridMath.rows(count: 0, width: 800, minimum: 210, spacing: 16).isEmpty)
    }

    @Test func itemsShareTheRowAfterSpacing() {
        #expect(GridMath.itemWidth(items: 3, width: 632, spacing: 16) == 200)
        #expect(GridMath.itemWidth(items: 1, width: 300, spacing: 16) == 300)
    }

    @Test func flowKeepsItemsOnOneRowWhenTheyFit() {
        #expect(GridMath.flowRows(widths: [90, 120, 90], width: 400, spacing: 18) == [0..<3])
        #expect(GridMath.flowRows(widths: [], width: 400, spacing: 18).isEmpty)
    }

    @Test func flowBalancesRowsWhenTheyWrap() {
        // Six of seven fit across: rows of four and three, not six and one.
        let widths = [Double](repeating: 90, count: 7)
        #expect(GridMath.flowRows(widths: widths, width: 650, spacing: 18) == [0..<4, 4..<7])
        // Uneven widths keep their order and never overflow a row.
        let mixed: [Double] = [80, 200, 80, 80, 150, 80]
        let rows = GridMath.flowRows(widths: mixed, width: 420, spacing: 10)
        #expect(rows.count == 2)
        #expect(rows.flatMap { Array($0) } == Array(0..<6))
        for row in rows {
            #expect(row.map { mixed[$0] }.reduce(0, +) + 10 * Double(row.count - 1) <= 420)
        }
    }

    @Test func flowGivesAnOversizedItemARowOfItsOwn() {
        #expect(GridMath.flowRows(widths: [50, 500, 50], width: 300, spacing: 10) == [0..<1, 1..<2, 2..<3])
    }

    @Test func spreadSharesTheSpareRoomEvenly() {
        #expect(GridMath.spread([100, 50], across: 280, spacing: 10) == [160, 110])
        // A row that's already too wide keeps its widths.
        #expect(GridMath.spread([200, 200], across: 300, spacing: 10) == [200, 200])
        #expect(GridMath.spread([], across: 300, spacing: 10).isEmpty)
    }
}
