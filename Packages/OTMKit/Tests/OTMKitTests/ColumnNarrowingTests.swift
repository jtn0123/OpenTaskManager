@testable import OTMKit
import Testing

struct ColumnNarrowingTests {
    /// Process, Local, Remote and State as a table left them after three
    /// columns hid: 591 points of columns, 193 of them above the minimums.
    private let widths: [Double] = [165, 155, 155, 116]
    private let minimums: [Double] = [100, 112, 112, 74]

    @Test func columnsThatFitAreLeftAlone() {
        #expect(ColumnFit.narrowed(widths: widths, minimums: minimums, by: 0) == widths)
        #expect(ColumnFit.narrowed(widths: widths, minimums: minimums, by: -40) == widths)
    }

    @Test func theExcessComesOffInProportionToEachColumnsRoom() {
        let narrowed = ColumnFit.narrowed(widths: widths, minimums: minimums, by: 174)
        #expect(abs(narrowed.reduce(0, +) - (591 - 174)) < 0.001)
        // Process had 65 points to spare and State 42, so Process gives up more.
        #expect(widths[0] - narrowed[0] > widths[3] - narrowed[3])
        for (width, minimum) in zip(narrowed, minimums) {
            #expect(width >= minimum)
        }
    }

    @Test func noColumnGoesUnderItsMinimum() {
        #expect(ColumnFit.narrowed(widths: widths, minimums: minimums, by: 400) == minimums)
    }

    @Test func aColumnAtItsMinimumKeepsIt() {
        let narrowed = ColumnFit.narrowed(widths: [100, 140], minimums: [100, 112], by: 20)
        #expect(narrowed == [100, 120])
    }

    @Test func columnsWithNoRoomStayAsTheyAre() {
        #expect(ColumnFit.narrowed(widths: minimums, minimums: minimums, by: 30) == minimums)
        #expect(ColumnFit.narrowed(widths: [], minimums: [], by: 30).isEmpty)
    }
}
