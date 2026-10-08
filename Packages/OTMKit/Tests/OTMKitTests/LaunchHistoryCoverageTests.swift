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

    @Test func spansNameEachDayOnceAndAMidnightCrossingNamesItsEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US_POSIX")
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        // 2 Oct 2026 00:00 UTC, then two spans that morning and one over the next midnight.
        let midnight = date(1_790_899_200)
        let spans = [LaunchHistoryInterval(start: midnight.addingTimeInterval(32_700), end: midnight.addingTimeInterval(32_820)),
                     LaunchHistoryInterval(start: midnight.addingTimeInterval(32_940), end: midnight.addingTimeInterval(33_120)),
                     LaunchHistoryInterval(start: midnight.addingTimeInterval(86_000), end: midnight.addingTimeInterval(87_000))]
        func at(_ offset: Double, _ style: Date.FormatStyle) -> String { midnight.addingTimeInterval(offset).formatted(style) }
        #expect(LaunchHistoryCoverage.spansText(spans, calendar: calendar, locale: locale)
            == "\(at(0, day)): \(at(32_700, time))–\(at(32_820, time)), \(at(32_940, time))–\(at(33_120, time)), "
            + "\(at(86_000, time))–\(at(87_000, day)) \(at(87_000, time))")
        #expect(at(0, day) != at(87_000, day))
        #expect(LaunchHistoryCoverage.spansText([], calendar: calendar, locale: locale).isEmpty)
    }
}
