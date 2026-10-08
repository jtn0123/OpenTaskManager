@testable import OTMKit
import Testing

struct ScrollSpyTests {
    /// Two columns, in page order: a long card on the left beside two short
    /// ones on the right, then a card under each.
    private let cards = [
        ScrollSpy.Card("processor", top: 200, bottom: 700),
        ScrollSpy.Card("memory", top: 200, bottom: 380),
        ScrollSpy.Card("graphics", top: 396, bottom: 520),
        ScrollSpy.Card("displays", top: 716, bottom: 900),
        ScrollSpy.Card("storage", top: 536, bottom: 1200),
    ]

    @Test func beforeAnyCardReachesTheTopTheFirstCounts() {
        #expect(ScrollSpy.current(cards, line: 24) == "processor")
    }

    @Test func theCardWhoseTopPassedLastCounts() {
        // Graphics has come up beside the long Processor card.
        #expect(ScrollSpy.current(cards, line: 400) == "graphics")
        // Storage, though Processor started first and still shows.
        #expect(ScrollSpy.current(cards, line: 600) == "storage")
        #expect(ScrollSpy.current(cards, line: 750) == "displays")
    }

    @Test func aCardScrolledPastNoLongerCounts() {
        // Graphics' top is the latest above the line, but it has gone by.
        #expect(ScrollSpy.current(cards, line: 530) == "processor")
        // Past every card: nothing.
        #expect(ScrollSpy.current(cards, line: 1300) == nil)
        #expect(ScrollSpy.current([ScrollSpy.Card<String>](), line: 0) == nil)
    }
}
