import Foundation
import Testing
@testable import OTMKit

struct ConnectionHistoryTests {
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func socket(pid: Int32 = 7, start: Double = 1, handle: UInt64 = 10, port: Int = 443,
                        state: TCPState = .established) -> Connection {
        Connection(id: .init(pid: pid, fd: 3, socket: handle), processName: "Browser", transport: .tcp, family: .ipv4,
                   local: Endpoint(address: "127.0.0.1", port: 50_000), remote: Endpoint(address: "192.0.2.1", port: port),
                   tcpState: state, processStart: date(start))
    }

    @Test func startsEndsAndMinuteBumpsOnly() throws {
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        watch.observe([socket()], at: date(100))
        let start = tracker.observe(watch, at: date(100), spacing: 3, hidden: 2)
        #expect(start.rows.count == 1)
        #expect(start.active.count == 1)
        let id = try #require(start.rows.first).id
        for time in stride(from: 103.0, through: 157.0, by: 3) {
            watch.observe([socket(state: .closeWait)], at: date(time))
            #expect(tracker.observe(watch, at: date(time), spacing: 3, hidden: 0).rows.isEmpty)
        }
        watch.observe([socket(state: .closeWait)], at: date(160))
        let bump = tracker.observe(watch, at: date(160), spacing: 3, hidden: 0)
        #expect(bump.rows.first?.id == id)
        #expect(bump.rows.first?.states == [.established, .closeWait])
        watch.observe([], at: date(163))
        let end = try #require(tracker.observe(watch, at: date(163), spacing: 3, hidden: 0).rows.first)
        #expect(end.id == id)
        #expect(end.socket.firstSeen == date(100))
        #expect(end.socket.lastSeen == date(160))
        #expect(end.closedBy == date(163))
        #expect(end.endedWords { String(Int($0.timeIntervalSince1970)) } == "Closed between 160 and 163")
    }

    @Test func reusedPIDDescriptorHandleAndPeerStartNewRows() throws {
        for replacement in [socket(pid: 7, start: 2), socket(handle: 11), socket(port: 80)] {
            var watch = ConnectionWatch()
            var tracker = ConnectionHistoryTracker()
            watch.observe([socket()], at: date(100))
            let original = try #require(tracker.observe(watch, at: date(100), spacing: 3, hidden: 0).rows.first)
            watch.observe([replacement], at: date(103))
            let batch = tracker.observe(watch, at: date(103), spacing: 3, hidden: 0)
            #expect(batch.rows.count == 2)
            #expect(batch.rows.contains { $0.id == original.id && $0.ending == .closed })
            #expect(batch.rows.contains { $0.id != original.id && $0.socket.firstSeen == date(103) })
        }
    }

    @Test func aGapStopOrUnreadableProcessNeverInventsAClosure() throws {
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        watch.observe([socket()], at: date(100))
        let first = try #require(tracker.observe(watch, at: date(100), spacing: 3, hidden: 0).rows.first)
        watch.observe([], at: date(120))
        let gap = try #require(tracker.observe(watch, at: date(120), spacing: 3, hidden: 0).rows.first)
        #expect(gap.id == first.id)
        #expect(gap.ending == .stopped)
        #expect(gap.closedBy == nil)
        #expect(gap.endedWords { _ in "unused" } == "Still open when watching stopped")
        watch.observe([socket()], at: date(123))
        _ = tracker.observe(watch, at: date(123), spacing: 3, hidden: 0)
        watch.observe([], at: date(126))
        let unread = try #require(tracker.observe(watch, at: date(126), spacing: 3, hidden: 1, unreadable: [7]).rows.first)
        #expect(unread.ending == .stopped)
        #expect(unread.closedBy == nil)
        watch.observe([socket()], at: date(129))
        _ = tracker.observe(watch, at: date(129), spacing: 3, hidden: 0)
        let stopped = try #require(tracker.stop().rows.first)
        watch.observe([socket()], at: date(132))
        let resumed = try #require(tracker.observe(watch, at: date(132), spacing: 3, hidden: 0).rows.first)
        #expect(resumed.id != stopped.id)
        #expect(resumed.socket.firstSeen == date(132))
        #expect(resumed.socket.timeline.first?.after == nil)
    }

    @Test func cadenceChangesKeepLifetimeAndResumedTimelinesKeepTheirFirstPhase() throws {
        var watch = ConnectionWatch(maximumSpacing: 121)
        var tracker = ConnectionHistoryTracker()
        watch.observe([socket()], at: date(100))
        let original = try #require(tracker.observe(watch, at: date(100), spacing: 3, hidden: 0).rows.first)
        watch.observe([socket()], at: date(160))
        let background = try #require(tracker.observe(watch, at: date(160), spacing: 60, hidden: 0).rows.first)
        #expect(background.id == original.id)
        #expect(background.socket.firstSeen == date(100))
        #expect(background.ending == .watching)
        _ = tracker.stop()
        watch.observe([socket()], at: date(200))
        _ = tracker.observe(watch, at: date(200), spacing: 3, hidden: 0)
        watch.observe([socket(state: .closeWait)], at: date(203))
        _ = tracker.observe(watch, at: date(203), spacing: 3, hidden: 0)
        let stopped = try #require(tracker.stop().rows.first)
        #expect(stopped.socket.firstSeen == date(200))
        #expect(stopped.socket.timeline.first?.kind == .opened(ConnectionPhase(socket())))
        #expect(stopped.socket.timeline.last?.kind == .changed(ConnectionPhase(socket(state: .closeWait))))
        #expect(stopped.states == [.established, .closeWait])
    }

    @Test func aStoppedRowCarriesOnWhenItsSocketIsFoundAgain() throws {
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        watch.observe([socket()], at: date(100))
        _ = tracker.observe(watch, at: date(100), spacing: 3, hidden: 0)
        let stopped = try #require(tracker.stop().rows.first)
        let key = try #require(socket().historyKey)
        // A later visit, or a relaunch with a fresh watch, finds the same socket.
        var fresh = ConnectionWatch()
        fresh.observe([socket(state: .closeWait)], at: date(400))
        let batch = tracker.observe(fresh, at: date(400), spacing: 3, hidden: 0, resumable: [key: stopped])
        let carried = try #require(batch.rows.first)
        #expect(batch.rows.count == 1)
        #expect(carried.id == stopped.id)
        #expect(carried.ending == .watching)
        #expect(carried.socket.firstSeen == date(100))
        #expect(carried.socket.lastSeen == date(400))
        #expect(carried.socket.timeline.contains { $0.kind == .unwatched })
        #expect(carried.states == [.established, .closeWait])
        // Another peer behind the same key, or a row seen closing, starts afresh.
        var closed = stopped
        closed.ending = .closed
        for (connection, row) in [(socket(port: 80), stopped), (socket(), closed)] {
            var other = ConnectionHistoryTracker()
            var walk = ConnectionWatch()
            walk.observe([connection], at: date(500))
            let started = try #require(other.observe(walk, at: date(500), spacing: 3, hidden: 0, resumable: [key: row]).rows.first)
            #expect(started.id != stopped.id)
            #expect(started.socket.firstSeen == date(500))
        }
        let unknownStart = Connection(id: .init(pid: 7, fd: 3, socket: 10), processName: "Browser", transport: .tcp, family: .ipv4,
                                      local: Endpoint(address: "127.0.0.1", port: 50_000), remote: nil, tcpState: nil)
        #expect(unknownStart.historyKey == nil)
    }

    @Test func aBreakInCoverageCarriesTheRowOnAndWritesItOnce() throws {
        var watch = ConnectionWatch(maximumSpacing: 10)
        var tracker = ConnectionHistoryTracker()
        watch.observe([socket()], at: date(100))
        let first = try #require(tracker.observe(watch, at: date(100), spacing: 3, hidden: 0).rows.first)
        // The Mac slept: the next walk is far past two spacings.
        watch.observe([socket()], at: date(900))
        let after = tracker.observe(watch, at: date(900), spacing: 3, hidden: 0)
        #expect(after.rows.count == 1)
        #expect(after.rows.first?.id == first.id)
        #expect(after.rows.first?.ending == .watching)
        #expect(after.rows.first?.socket.firstSeen == date(100))
    }

    @Test func searchMatchesNamePathAddressHostServicePortAndPID() throws {
        var watch = ConnectionWatch()
        watch.observe([socket()], at: date(100))
        let row = ConnectionLifetime(socket: try #require(watch.open.first),
                                     process: .init(name: "Example Browser", path: "/Applications/Example.app", user: "me"))
        for query in ["browser", "example.app", "192.0.2", "192.0.2.1:443", "https", "443", "7", "  EXAMPLE  ", ""] {
            #expect(row.matches(query))
        }
        for query in ["4430", "50", "777", "unknown"] { #expect(!row.matches(query)) }
        let host = Connection(id: .init(pid: 7, fd: 4, socket: 12), processName: "host", transport: .udp, family: .ipv4,
                              local: Endpoint(address: "example.local", port: 53), remote: nil, tcpState: nil)
        watch.observe([host], at: date(103))
        #expect(ConnectionLifetime(socket: try #require(watch.open.first), process: row.process).matches("example.local"))
    }

    @Test func retentionAndCapPreferOldEndedRows() throws {
        var watch = ConnectionWatch()
        watch.observe([socket()], at: date(10))
        let old = ConnectionLifetime(id: "old", socket: try #require(watch.open.first), process: .init(name: "a", path: nil, user: "me"))
        watch.observe([], at: date(13))
        watch.observe([socket()], at: date(20))
        let new = ConnectionLifetime(id: "new", socket: try #require(watch.open.first), process: old.process)
        #expect(ConnectionHistoryRetention.retained([old, new], active: [], before: date(15)).map(\.id) == ["new"])
        #expect(ConnectionHistoryRetention.retained([old, new], active: ["old"], before: date(0), limit: 1).map(\.id) == ["old"])
        #expect(ConnectionHistoryRetention.retained([old, new], active: [], before: date(0), limit: 1).map(\.id) == ["new"])
        #expect(ConnectionHistoryRetention.retained([old], active: ["old"], before: date(15)).isEmpty)
    }

    @Test func timelinesStayBoundedButKeepEveryTCPStateSeen() throws {
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        for index in 0..<100 {
            let state = TCPState.allCases[index % TCPState.allCases.count]
            let time = date(100 + Double(index) * 3)
            watch.observe([socket(state: state)], at: time)
            _ = tracker.observe(watch, at: time, spacing: 3, hidden: 0)
        }
        let row = try #require(tracker.stop().rows.first)
        #expect(row.socket.timeline.count == ConnectionWatch.keptEvents)
        #expect(row.socket.droppedEvents > 0)
        #expect(row.socket.timeline.first?.time == date(100))
        #expect(Set(row.states) == Set(TCPState.allCases))
    }

    @Test func intervalPickerUsesCalendarTodayAndRollingHourAndWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let end = date(90_000)
        #expect(ConnectionHistoryRange.today.start(before: end, calendar: calendar) == date(86_400))
        #expect(ConnectionHistoryRange.hour.start(before: end, calendar: calendar) == date(86_400))
        #expect(ConnectionHistoryRange.week.start(before: end, calendar: calendar) == end.addingTimeInterval(-FlightRecorder.retention))
    }

    @Test func coverageBreaksOnGapsStopsAndCadenceChangesAndClips() {
        var tracker = ConnectionCoverageTracker()
        let first = tracker.observe(at: date(100), spacing: 3, hidden: 2)
        let extended = tracker.observe(at: date(103), spacing: 3, hidden: 4)
        #expect(extended.id == first.id)
        #expect(extended.hiddenProcesses == 4)
        #expect(extended.walks == 2)
        let gap = tracker.observe(at: date(111), spacing: 3, hidden: 1)
        #expect(gap.id != first.id)
        let background = tracker.observe(at: date(120), spacing: 60, hidden: 0)
        #expect(background.id != gap.id)
        #expect(background.start == date(111))
        let backgroundEnd = tracker.observe(at: date(180), spacing: 60, hidden: 3)
        #expect(backgroundEnd.id == background.id)
        tracker.stop()
        #expect(tracker.observe(at: date(181), spacing: 60, hidden: 0).id != background.id)
        let coverage = ConnectionHistoryCoverage(from: date(101), to: date(200), intervals: [extended, gap, backgroundEnd])
        #expect(coverage.watchedSeconds == 71)
        #expect(coverage.gaps == 2)
        #expect(coverage.isWatched(at: date(150)))
        #expect(!coverage.isWatched(at: date(110)))
        #expect(coverage.intervals.first?.start == date(101))
        #expect(coverage.watchedWords.contains("not watched"))
        let none = ConnectionHistoryCoverage(from: date(0), to: date(10), intervals: [])
        #expect(none.gaps == 1)
        #expect(none.watchedWords.hasPrefix("Not watched"))
        #expect(none.summary.hasSuffix(" · 1 gap"))
        let one = ConnectionHistoryCoverage(from: date(0), to: date(10), intervals: [
            ConnectionWatchInterval(start: date(0), end: date(10), spacing: 3, hiddenProcesses: 1)
        ], droppedRows: 1)
        #expect(one.summary.hasSuffix(" · 0 gaps · up to 1 process unreadable per interval · 1 oldest lifetime dropped at the row limit"))
    }
}
