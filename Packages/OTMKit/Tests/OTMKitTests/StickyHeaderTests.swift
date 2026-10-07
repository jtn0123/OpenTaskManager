@testable import OTMKit
import Testing

struct StickyHeaderTests {
    private func offset(_ visibleTop: Double) -> Double {
        StickyHeader.offset(visibleTop: visibleTop, tableHeight: 1000, headerHeight: 48)
    }

    @Test func staysAtTheTopWhileTheTableTopShows() {
        #expect(offset(-300) == 0)
        #expect(offset(0) == 0)
    }

    @Test func followsTheVisibleTopOnceScrolledPast() {
        #expect(offset(1) == 1)
        #expect(offset(400) == 400)
    }

    @Test func theTableEndPushesItOut() {
        // It stops where its bottom meets the table's, and leaves with it.
        #expect(offset(952) == 952)
        #expect(offset(990) == 952)
        #expect(offset(5000) == 952)
    }

    @Test func aTableShorterThanItsHeaderKeepsItAtTheTop() {
        #expect(StickyHeader.offset(visibleTop: 30, tableHeight: 20, headerHeight: 48) == 0)
        #expect(StickyHeader.offset(visibleTop: .nan, tableHeight: 1000, headerHeight: 48) == 0)
    }
}
