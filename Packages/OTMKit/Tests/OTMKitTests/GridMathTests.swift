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
}
