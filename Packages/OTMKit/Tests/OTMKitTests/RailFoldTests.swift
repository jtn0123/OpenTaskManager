@testable import OTMKit
import Testing

struct RailFoldTests {
    /// The card sits unpinned at 86; the charts begin at 252 below the whole card.
    private func scrolled(_ fold: inout RailFold, to visibleTop: Double) {
        fold.scrolled(visibleTop: visibleTop, railTop: 86, chartsTop: 252)
    }

    @Test func foldsOnceTheChartsTopHasScrolledOutOfView() {
        var fold = RailFold()
        #expect(fold.state == .whole)
        scrolled(&fold, to: 0)
        #expect(!fold.isFolded)
        // Pinned over the charts, but their top still shows under it.
        scrolled(&fold, to: 200)
        #expect(!fold.isFolded)
        scrolled(&fold, to: 252)
        #expect(fold.isFolded)
        scrolled(&fold, to: 1_400)
        #expect(fold.isFolded)
    }

    @Test func staysFoldedUntilTheCardIsBackInItsPlace() {
        var fold = RailFold()
        scrolled(&fold, to: 600)
        // Back up between the two lines: the strip's lower height moved the
        // charts up, which mustn't unfold it.
        scrolled(&fold, to: 150)
        #expect(fold.isFolded)
        scrolled(&fold, to: 86)
        #expect(fold.state == .whole)
        // And between the lines on the way down it stays whole.
        scrolled(&fold, to: 150)
        #expect(fold.state == .whole)
    }

    @Test func openedFromTheStripItStaysOpenUntilTheTop() {
        var fold = RailFold()
        // Nothing to open while it's whole.
        fold.open()
        #expect(fold.state == .whole)
        scrolled(&fold, to: 600)
        fold.open()
        #expect(fold.state == .opened)
        scrolled(&fold, to: 1_200)
        #expect(fold.state == .opened)
        fold.fold()
        #expect(fold.isFolded)
        fold.open()
        scrolled(&fold, to: 40)
        #expect(fold.state == .whole)
        // Back down, it folds as before.
        scrolled(&fold, to: 300)
        #expect(fold.isFolded)
    }

    @Test func foldsOnlyFromTheWholeCard() {
        var fold = RailFold()
        fold.fold()
        #expect(fold.state == .whole)
        // Charts measured above the card (before a layout) never fold it at its own place.
        fold.scrolled(visibleTop: 50, railTop: 86, chartsTop: 10)
        #expect(fold.state == .whole)
        fold.scrolled(visibleTop: .nan, railTop: 86, chartsTop: 252)
        #expect(fold.state == .whole)
    }
}
