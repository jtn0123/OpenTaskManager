import Foundation
import Testing
@testable import OTMKit

struct LaunchHistoryCoverageTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func readsExtendSplitAndStayIndependentByDomain() throws {
        var tracker = LaunchHistoryReadTracker()
        let firstRead = tracker.observe(domain: "system", at: date(1_000))
        let first = try #require(firstRead)
        #expect(!first.extends)
        #expect(first.interval == LaunchHistoryInterval(start: date(1_000), end: date(1_000)))
        let nextRead = tracker.observe(domain: "system", at: date(1_060))
        let next = try #require(nextRead)
        #expect(next.extends)
        #expect(next.interval == LaunchHistoryInterval(start: date(1_000), end: date(1_060)))
        #expect(tracker.observe(domain: "gui/501", at: date(1_070))?.extends == false)
        #expect(tracker.observe(domain: "system", at: date(1_150))?.extends == true, "90 s is still continuous")
        #expect(tracker.observe(domain: "system", at: date(1_241))?.extends == false)
        tracker.interrupt(domain: "system", at: date(1_250))
        #expect(tracker.observe(domain: "system", at: date(1_260))?.extends == false, "a failed domain read breaks coverage")
        #expect(tracker.observe(domain: "gui/501", at: date(1_150))?.extends == true, "another domain's failure doesn't stop this one")
        #expect(tracker.observe(domain: "system", at: date(1_260)) == nil)
        #expect(tracker.observe(domain: "system", at: date(1_000)) == nil)
        tracker.interrupt(domain: "system", at: date(1_000))
        #expect(tracker.observe(domain: "system", at: date(1_270))?.extends == true, "an older failure cannot break newer coverage")
    }

    @Test func overlapIsCountedOnceAndHolesStayUnwatched() {
        let intervals = [LaunchHistoryInterval(start: date(0), end: date(100)),
                         LaunchHistoryInterval(start: date(20), end: date(200)),
                         LaunchHistoryInterval(start: date(200), end: date(210)),
                         LaunchHistoryInterval(start: date(220), end: date(230))]
        #expect(LaunchHistoryCoverage.merged(intervals).count == 2)
        #expect(LaunchHistoryCoverage.seconds(intervals, from: date(50), to: date(225)) == 165)
        #expect(LaunchHistoryCoverage.watches(intervals, from: date(0), to: date(210)))
        #expect(!LaunchHistoryCoverage.watches(intervals, from: date(100), to: date(225)))
        #expect(!LaunchHistoryCoverage.watches(intervals, from: date(0), to: date(231)))
        let end = date(100_000)
        let watched = [LaunchHistoryInterval(start: end.addingTimeInterval(-11_400), end: end)]
        #expect(LaunchHistoryCoverage.caption(watched, at: end)
            == "Watched 3 h 10 min of the last 24 h; changes between reads are bounded, not timed")
    }
}
