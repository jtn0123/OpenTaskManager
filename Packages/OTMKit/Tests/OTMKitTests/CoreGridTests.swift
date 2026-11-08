@testable import OTMKit
import Testing

struct CoreGridTests {
    private func grid(_ counts: [Int], width: Double) -> CoreGrid {
        CoreGrid(counts: counts, width: width, minimum: 96, spacing: 6, groupSpacing: 18)
    }

    @Test func oneKindOfCoreFillsOneRowWhenItFits() {
        // A six-core VM in a wide card: six tiles spanning the width.
        let plan = grid([6], width: 936)
        #expect(plan.columns == 6)
        #expect(!plan.sharesRow)
        #expect(abs(plan.tileWidth - 151) < 0.01)
        #expect(plan.rows(count: 6) == [0..<6])
    }

    @Test func manyCoresOfOneKindSpreadEvenlyOverRows() {
        // Nine fit across: eighteen go two rows of nine.
        let wide = grid([18], width: 936)
        #expect(wide.columns == 9)
        #expect(wide.rows(count: 18) == [0..<9, 9..<18])
        // Seven fit across: three rows of six, not seven, seven and four.
        let narrow = grid([18], width: 752)
        #expect(narrow.columns == 6)
        #expect(narrow.rows(count: 18) == [0..<6, 6..<12, 12..<18])
    }

    @Test func groupsThatFitOneLineSitSideBySide() {
        // Four performance and four efficiency cores in a wide card.
        let plan = grid([4, 4], width: 936)
        #expect(plan.sharesRow)
        #expect(plan.columns == 8)
        #expect(plan.rows(count: 4) == [0..<4])
        // Every tile and gap adds up to the width, the gap between groups wider.
        #expect(abs(plan.tileWidth * 8 + 6 * 6 + 18 - 936) < 0.01)
    }

    @Test func groupsThatDontFitOneLineTakeRowsWithSharedColumns() {
        // Twelve and six on a Mac with eighteen logical CPUs: rows of six for both.
        let plan = grid([12, 6], width: 936)
        #expect(!plan.sharesRow)
        #expect(plan.columns == 6)
        #expect(plan.rows(count: 12) == [0..<6, 6..<12])
        #expect(plan.rows(count: 6) == [0..<6])
        // Four and six that don't fit one line: the six set the columns, the four leave room.
        let mixed = grid([4, 6], width: 900)
        #expect(mixed.columns == 6)
        #expect(mixed.rows(count: 4) == [0..<4])
    }

    @Test func aShortLastRowIsBalancedNotLeftAlone() {
        let plan = CoreGrid(columns: 6, sharesRow: false, tileWidth: 100)
        #expect(plan.rows(count: 7) == [0..<4, 4..<7])
        #expect(plan.rows(count: 13) == [0..<5, 5..<10, 10..<13])
        #expect(plan.rows(count: 0).isEmpty)
    }

    @Test func aNarrowContainerStillGetsOneColumn() {
        let plan = grid([12, 4], width: 60)
        #expect(plan.columns == 1)
        #expect(abs(plan.tileWidth - 60) < 0.01)
        #expect(plan.rows(count: 4).count == 4)
    }

    @Test func noCoresMeansNoTiles() {
        let plan = grid([], width: 936)
        #expect(plan.columns == 1)
        #expect(plan.rows(count: 0).isEmpty)
        #expect(!grid([0, 0], width: 936).sharesRow)
        #expect(grid([6], width: .infinity).columns == 1)
    }
}
