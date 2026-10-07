import Foundation
@testable import OTMKit
import Testing

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
}

/// "+90" for a date 90 seconds after `start`, so notes read the same in any time zone.
private func offset(_ date: Date) -> String {
    "+\(Int(date.timeIntervalSince(start)))"
}

/// A fixture socket. The kernel handle defaults to one per descriptor, and
/// the process started an hour before `start`.
private func socket(_ transport: Connection.Transport = .tcp, pid: Int32 = 100, started: TimeInterval? = -3600,
                    fd: Int32, handle: UInt64? = nil, local: (String, Int), remote: (String, Int)? = nil,
                    state: TCPState? = nil) -> Connection {
    Connection(
        id: Connection.SocketID(pid: pid, fd: fd, socket: handle ?? UInt64(fd) * 0x1000),
        processName: "test", transport: transport, family: .ipv4,
        local: Endpoint(address: local.0, port: local.1),
        remote: remote.map { Endpoint(address: $0.0, port: $0.1) },
        tcpState: transport == .tcp ? state : nil,
        processStart: started.map(at)
    )
}

private let listener = socket(fd: 5, local: ("127.0.0.1", 54321), state: .listen)
private let client = socket(fd: 6, local: ("127.0.0.1", 49201), remote: ("127.0.0.1", 54321), state: .established)

struct ConnectionWatchTests {
    @Test func theFirstWalkFindsEverythingAlreadyOpen() throws {
        var watch = ConnectionWatch()
        watch.observe([listener, client], at: at(0))
        #expect(watch.open.count == 2)
        #expect(watch.closed.isEmpty)
        #expect(watch.firstWalk == at(0))
        let first = try #require(watch.open.first)
        #expect(first.wasOpenAtFirstLook)
        #expect(first.seenFor == 0)
        #expect(first.timeline == [ConnectionEvent(kind: .opened(ConnectionPhase(listener)), time: at(0), after: nil)])
        // It was listening before anything looked, so it isn't new.
        #expect(first.listeningSince == nil)
        #expect(!first.isNewListener(at: at(0)))
    }

    @Test func aSocketSeenAgainKeepsItsIDAndCountsTheTimeSeen() throws {
        var watch = ConnectionWatch()
        watch.observe([listener, client], at: at(0))
        let ids = watch.open.map(\.id)
        watch.observe([listener, client], at: at(3))
        watch.observe([client, listener], at: at(6))
        #expect(Set(watch.open.map(\.id)) == Set(ids))
        let seen = try #require(watch.open.first { $0.id == ids[0] })
        #expect(seen.firstSeen == at(0))
        #expect(seen.lastSeen == at(6))
        #expect(seen.seenFor == 6)
        #expect(seen.timeline.count == 1, "nothing changed")
        #expect(watch.closed.isEmpty)
    }

    @Test func aSocketThatAppearsLaterOpenedSinceTheWalkBefore() throws {
        var watch = ConnectionWatch()
        watch.observe([client], at: at(0))
        let server = socket(fd: 9, local: ("0.0.0.0", 8080), state: .listen)
        watch.observe([client, server], at: at(3))
        let new = try #require(watch.open.first { $0.connection == server })
        #expect(!new.wasOpenAtFirstLook)
        #expect(new.timeline.first?.after == at(0))
        #expect(new.timeline.first?.isAfterGap == false)
        #expect(new.listeningSince == at(3))
        #expect(new.isNewListener(at: at(3)))
        #expect(new.isNewListener(at: at(3 + ConnectionWatch.newListenerWindow - 1)))
        #expect(!new.isNewListener(at: at(3 + ConnectionWatch.newListenerWindow)), "new only for a while")
        // A new outgoing connection isn't a listener.
        let outgoing = socket(fd: 10, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)
        watch.observe([client, server, outgoing], at: at(6))
        #expect(watch.open.first { $0.connection == outgoing }?.isNewListener(at: at(6)) == false)
    }

    @Test func aSocketNoLongerFoundHasClosed() throws {
        var watch = ConnectionWatch()
        watch.observe([listener, client], at: at(0))
        watch.observe([listener], at: at(3))
        #expect(watch.open.map(\.connection) == [listener])
        let gone = try #require(watch.closed.first)
        #expect(gone.connection == client)
        #expect(!gone.isOpen)
        #expect(gone.closedBy == at(3))
        #expect(gone.lastSeen == at(0))
        #expect(gone.seenFor == 0)
        #expect(gone.timeline.last == ConnectionEvent(kind: .closed, time: at(3), after: at(0)))
        #expect(!gone.isNewListener(at: at(3)))
    }

    @Test func aReusedDescriptorWithAnotherHandleIsANewSocket() throws {
        var watch = ConnectionWatch()
        let before = socket(fd: 7, handle: 0xAAAA, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)
        watch.observe([before], at: at(0))
        let oldID = try #require(watch.open.first?.id)
        // The process closed descriptor 7 and the next socket it opened got it again.
        let after = socket(fd: 7, handle: 0xBBBB, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)
        watch.observe([after], at: at(3))
        #expect(watch.closed.map(\.id) == [oldID])
        let new = try #require(watch.open.first)
        #expect(new.id != oldID)
        #expect(new.firstSeen == at(3))
        #expect(new.timeline.first?.after == at(0))
    }

    @Test func aReusedDescriptorAndHandleOnAnotherPortOrPeerIsANewSocket() {
        var watch = ConnectionWatch()
        let first = socket(fd: 7, handle: 0xAAAA, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)
        watch.observe([first], at: at(0))
        let otherPort = socket(fd: 7, handle: 0xAAAA, local: ("10.0.0.2", 50001), remote: ("1.1.1.1", 443), state: .established)
        watch.observe([otherPort], at: at(3))
        #expect(watch.closed.count == 1)
        let otherPeer = socket(fd: 7, handle: 0xAAAA, local: ("10.0.0.2", 50001), remote: ("8.8.8.8", 443), state: .established)
        watch.observe([otherPeer], at: at(6))
        #expect(watch.closed.count == 2)
        #expect(watch.open.count == 1)
        #expect(Set(watch.closed.map(\.id) + watch.open.map(\.id)).count == 3, "IDs are never reused")
    }

    @Test func aReusedPIDIsAnotherProcessesSocket() {
        var watch = ConnectionWatch()
        watch.observe([socket(pid: 300, started: -60, fd: 4, local: ("127.0.0.1", 3000), state: .listen)], at: at(0))
        // The process ended and macOS gave its PID to one that bound the same port on the same descriptor.
        watch.observe([socket(pid: 300, started: 1, fd: 4, local: ("127.0.0.1", 3000), state: .listen)], at: at(3))
        #expect(watch.closed.count == 1)
        #expect(watch.open.first?.firstSeen == at(3))
        #expect(watch.open.first?.isNewListener(at: at(3)) == true)
    }

    @Test func aSocketKeepsItsPortAndPeerButCanGainThem() {
        let bound = socket(.udp, fd: 3, local: ("0.0.0.0", 60000))
        let connected = socket(.udp, fd: 3, local: ("10.0.0.2", 60000), remote: ("8.8.8.8", 53))
        #expect(ConnectionWatch.continues(bound, as: connected), "a wildcard bind narrows on connect")
        #expect(!ConnectionWatch.continues(connected, as: socket(.udp, fd: 3, local: ("10.0.0.3", 60000), remote: ("8.8.8.8", 53))))
        #expect(!ConnectionWatch.continues(bound, as: socket(.udp, fd: 3, local: ("0.0.0.0", 60001))))
        #expect(!ConnectionWatch.continues(connected, as: socket(.udp, fd: 3, local: ("10.0.0.2", 60000), remote: ("1.1.1.1", 53))))
        let unbound = socket(fd: 8, local: ("0.0.0.0", 0), remote: ("1.1.1.1", 443), state: .synSent)
        #expect(ConnectionWatch.continues(unbound, as: socket(fd: 8, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443),
                                                               state: .established)))
    }

    @Test func notesStateChangesInOrder() throws {
        var watch = ConnectionWatch()
        let opening = socket(fd: 8, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .synSent)
        watch.observe([], at: at(0))
        watch.observe([opening], at: at(3))
        watch.observe([socket(fd: 8, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)], at: at(6))
        watch.observe([socket(fd: 8, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)], at: at(9))
        watch.observe([socket(fd: 8, local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .closeWait)], at: at(12))
        watch.observe([], at: at(15))
        let gone = try #require(watch.closed.first)
        #expect(gone.timeline.map(\.title) == [
            "Opened · SYN sent · 1.1.1.1:443", "Established · 1.1.1.1:443", "Close wait · 1.1.1.1:443", "Closed",
        ])
        #expect(gone.timeline.map(\.time) == [at(3), at(6), at(12), at(15)])
        #expect(gone.timeline.map(\.after) == [at(0), at(3), at(9), at(12)])
        #expect(gone.seenFor == 9)
    }

    @Test func startingToListenMakesAListenerNew() throws {
        var watch = ConnectionWatch()
        // Bound, not yet listening: TCP's "closed" state.
        watch.observe([socket(fd: 4, local: ("0.0.0.0", 8080), state: .closed)], at: at(0))
        #expect(watch.open.first?.listeningSince == nil)
        watch.observe([socket(fd: 4, local: ("0.0.0.0", 8080), state: .listen)], at: at(3))
        let server = try #require(watch.open.first)
        #expect(server.listeningSince == at(3))
        #expect(server.isNewListener(at: at(10)))
        // A bound UDP socket that connects stops taking traffic from anyone.
        watch.observe([socket(.udp, fd: 5, local: ("0.0.0.0", 5000))], at: at(6))
        #expect(watch.open.first?.isNewListener(at: at(6)) == true)
        watch.observe([socket(.udp, fd: 5, local: ("10.0.0.2", 5000), remote: ("10.0.0.9", 5000))], at: at(9))
        #expect(watch.open.first?.listeningSince == nil)
        #expect(watch.open.first?.isNewListener(at: at(9)) == false)
    }

    @Test func aGapInTheWatchIsNoted() throws {
        var watch = ConnectionWatch()
        watch.observe([listener, client], at: at(0))
        // The page closed for ten minutes.
        let server = socket(fd: 9, local: ("0.0.0.0", 8080), state: .listen)
        watch.observe([listener, server], at: at(600))
        let kept = try #require(watch.open.first { $0.connection == listener })
        #expect(kept.timeline.last == ConnectionEvent(kind: .unwatched, time: at(600), after: at(0), isAfterGap: true))
        #expect(kept.seenFor == 600)
        let new = try #require(watch.open.first { $0.connection == server })
        #expect(new.timeline.first?.isAfterGap == true)
        #expect(new.timeline.first?.note(time: offset) == "Some time after +0, while not watched")
        #expect(new.isNewListener(at: at(600)), "new to the watch")
        let gone = try #require(watch.closed.first)
        #expect(gone.timeline.last?.isAfterGap == true)
        // Walks at the usual spacing have no gap.
        watch.observe([listener, server], at: at(603))
        #expect(watch.open.first { $0.id == kept.id }?.timeline == kept.timeline)
    }

    @Test func keepsTheLatestClosedSocketsOnly() {
        var watch = ConnectionWatch()
        let count = ConnectionWatch.keptClosed + 20
        let all = (0..<count).map { socket(fd: Int32($0), local: ("127.0.0.1", 40000 + $0), state: .listen) }
        watch.observe(all, at: at(0))
        // Close them one walk at a time, oldest descriptor first.
        for closed in 1...count {
            watch.observe(Array(all.dropFirst(closed)), at: at(Double(closed) * 0.01))
        }
        #expect(watch.open.isEmpty)
        #expect(watch.closed.count == ConnectionWatch.keptClosed)
        #expect(watch.closed.first?.connection.id.fd == 20, "the first 20 to close are dropped")
        #expect(watch.closed.last?.connection.id.fd == Int32(count - 1))
    }

    @Test func forgetsClosedSocketsLastSeenLongAgo() {
        var watch = ConnectionWatch()
        watch.observe([listener, client], at: at(0))
        watch.observe([listener], at: at(3))
        #expect(watch.closed.count == 1)
        // Still open, the listener keeps being seen; the client was last seen at 0.
        watch.observe([listener], at: at(ConnectionWatch.closedWindow))
        #expect(watch.closed.count == 1)
        watch.observe([listener], at: at(ConnectionWatch.closedWindow + 3))
        #expect(watch.closed.isEmpty)
        #expect(watch.open.count == 1)
    }

    @Test func keepsATimelineShortButItsFirstStep() throws {
        var watch = ConnectionWatch()
        watch.observe([], at: at(0))
        // A UDP socket that connects and disconnects every walk.
        for walk in 1...30 {
            let remote = walk.isMultiple(of: 2) ? ("10.0.0.9", 5000) : nil
            watch.observe([socket(.udp, fd: 3, local: ("0.0.0.0", 5000), remote: remote)], at: at(Double(walk) * 3))
        }
        let flapping = try #require(watch.open.first)
        #expect(flapping.timeline.count == ConnectionWatch.keptEvents)
        #expect(flapping.timeline.first?.time == at(3), "the opening stays")
        #expect(flapping.timeline.last?.time == at(90))
        #expect(flapping.droppedEvents == 30 - ConnectionWatch.keptEvents)
    }

    @Test func describesEachStep() {
        let phase = ConnectionPhase(client)
        #expect(phase.summary == "Established · 127.0.0.1:54321")
        #expect(ConnectionPhase(listener).summary == "Listening")
        #expect(ConnectionPhase(socket(.udp, fd: 3, local: ("0.0.0.0", 5353))).summary == "Bound")
        let already = ConnectionEvent(kind: .opened(phase), time: at(0), after: nil)
        #expect(already.title == "Established · 127.0.0.1:54321")
        #expect(already.note(time: offset) == "Already open at the first look, so it may be older")
        let opened = ConnectionEvent(kind: .opened(phase), time: at(3), after: at(0))
        #expect(opened.title == "Opened · Established · 127.0.0.1:54321")
        #expect(opened.note(time: offset) == nil, "a walk's few seconds need no note")
        let gap = ConnectionEvent(kind: .unwatched, time: at(600), after: at(3), isAfterGap: true)
        #expect(gap.title == "Not watched")
        #expect(gap.note(time: offset) == "The page was closed or updates paused until +600")
        #expect(ConnectionEvent(kind: .closed, time: at(9), after: at(6)).title == "Closed")
    }

    @Test func summarisesWhatWasSeen() throws {
        var watch = ConnectionWatch()
        watch.observe([listener], at: at(0))
        watch.observe([listener, client], at: at(3))
        watch.observe([listener, client], at: at(136.5))
        let already = try #require(watch.open.first { $0.connection == listener })
        #expect(already.seenSummary(time: offset) == """
        Seen for 2 min 16 s, since +0. It was already open at the page's first look, so it may be older.
        """)
        let opened = try #require(watch.open.first { $0.connection == client })
        #expect(opened.seenSummary(time: offset) == "Seen for 2 min 13 s: it opened between +0 and +3.")
        // The page closes for a while; the client is gone when it comes back.
        let server = socket(fd: 9, local: ("0.0.0.0", 8080), state: .listen)
        watch.observe([listener, server], at: at(300))
        let gone = try #require(watch.closed.first)
        #expect(gone.seenSummary(time: offset) == """
        Seen for 2 min 13 s: it opened between +0 and +3. Last seen at +136, gone by +300.
        """)
        let new = try #require(watch.open.first { $0.connection == server })
        #expect(new.seenSummary(time: offset) == """
        Seen for 0 s, since +300. It opened while the page wasn't watching, some time after +136.
        """)
    }

    static let spans: [(TimeInterval, String)] = [
        (0, "0 s"), (59.9, "59 s"), (60, "1 min"), (119, "1 min"), (3599, "59 min"), (3600, "1 h"),
        (3900, "1 h 5 min"), (86_399, "23 h 59 min"), (86_400, "1 day"), (183_659, "2 days 3 h"), (-5, "0 s"),
    ]

    @Test(arguments: spans)
    func spansRoundDown(seconds: TimeInterval, expected: String) {
        #expect(ObservedConnection.span(seconds) == expected)
    }
}
