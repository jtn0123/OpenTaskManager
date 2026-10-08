import Foundation

/// What a socket was doing at one walk: its kind, its TCP state and its
/// peer. A change in any of them is a step in its observed timeline.
public struct ConnectionPhase: Sendable, Hashable {
    public let kind: ConnectionKind
    public let tcpState: TCPState?
    public let remote: Endpoint?

    public init(_ connection: Connection) {
        kind = connection.kind
        tcpState = connection.tcpState
        remote = connection.remote
    }

    /// As the State column says it: "Established", "Listening", "Bound".
    public var label: String { tcpState?.label ?? kind.label }

    /// The state with the peer, when there is one: "Established · 1.1.1.1:443".
    public var summary: String {
        remote.map { "\(label) · \($0.formatted)" } ?? label
    }
}

/// One step in a socket's timeline as OpenTaskManager saw it.
///
/// Times are the socket walk's, not the kernel's, which keeps none: the
/// walk runs every few seconds while the Connections page is open, so a step
/// happened after the walk before (`after`) and by the one that saw it (`time`).
public struct ConnectionEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// First seen, doing this.
        case opened(ConnectionPhase)
        /// Seen doing something other than at the walk before.
        case changed(ConnectionPhase)
        /// Nothing watched it between `after` and `time` (the page was
        /// closed, or updates paused), though it was there at both.
        case unwatched
        /// Gone: closed by its process or the other end, or its process ended.
        case closed
    }

    public let kind: Kind
    /// The walk that saw it.
    public let time: Date
    /// The walk before, which hadn't seen it yet. Nil for a socket already
    /// open at the first walk, which may be any age.
    public let after: Date?
    /// Nothing watched between `after` and `time`, so it can have happened
    /// any time in that stretch, not just in the few seconds before `time`.
    public let isAfterGap: Bool

    public init(kind: Kind, time: Date, after: Date?, isAfterGap: Bool = false) {
        self.kind = kind
        self.time = time
        self.after = after
        self.isAfterGap = isAfterGap
    }

    /// The step in a few words: "Opened · Listening", "Established · 1.1.1.1:443", "Closed".
    public var title: String {
        switch kind {
        case let .opened(phase): after == nil ? phase.summary : "Opened · \(phase.summary)"
        case let .changed(phase): phase.summary
        case .unwatched: "Not watched"
        case .closed: "Closed"
        }
    }

    /// When it happened, where the time alone would claim too much: a
    /// socket already open at the first look, a step after a gap, or the
    /// gap itself. `time` formats a clock time.
    public func note(time format: (Date) -> String) -> String? {
        if case .unwatched = kind {
            return "The page was closed or updates paused until \(format(time))"
        }
        guard let after else { return "Already open at the first look, so it may be older" }
        return isAfterGap ? "Some time after \(format(after)), while not watched" : nil
    }
}

/// A socket as OpenTaskManager has followed it: when a walk first found
/// it, when one last did, and what it was seen doing in between.
public struct ObservedConnection: Sendable, Identifiable {
    /// Given in the order sockets are found, never reused in a session,
    /// unlike descriptors and PIDs.
    public let id: UInt64
    /// The latest reading; for a closed socket, the last one before it went.
    public fileprivate(set) var connection: Connection
    /// The walk that first found it.
    public let firstSeen: Date
    /// The latest walk that found it.
    public fileprivate(set) var lastSeen: Date
    /// The walk that found it gone; nil while it's open.
    public fileprivate(set) var closedBy: Date?
    /// When it was found taking traffic from anyone (listening, or bound
    /// UDP), if a walk before showed it wasn't yet: it wasn't there, or did
    /// something else. Nil for one already listening at the first walk.
    public fileprivate(set) var listeningSince: Date?
    /// Its steps, oldest first: the first always, then the latest, at most
    /// `ConnectionWatch.keptEvents` in all.
    public fileprivate(set) var timeline: [ConnectionEvent]
    /// Steps left out after the first to keep `timeline` short.
    public fileprivate(set) var droppedEvents = 0

    fileprivate init(id: UInt64, connection: Connection, at date: Date, after previous: Date?, isAfterGap: Bool) {
        self.id = id
        self.connection = connection
        firstSeen = date
        lastSeen = date
        listeningSince = previous != nil && connection.kind.acceptsInbound ? date : nil
        timeline = [ConnectionEvent(kind: .opened(ConnectionPhase(connection)), time: date, after: previous, isAfterGap: isAfterGap)]
    }

    public var isOpen: Bool { closedBy == nil }

    /// Already there at the first walk, so it may be much older than the watch.
    public var wasOpenAtFirstLook: Bool { timeline.first?.after == nil }

    /// How long OpenTaskManager has seen it: from the walk that first found
    /// it to the latest that did. Never how old the socket is.
    public var seenFor: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }

    /// Seen starting to listen less than `ConnectionWatch.newListenerWindow` before `date`, and still listening.
    public func isNewListener(at date: Date) -> Bool {
        guard isOpen, connection.kind.acceptsInbound, let listeningSince else { return false }
        return date.timeIntervalSince(listeningSince) < ConnectionWatch.newListenerWindow
    }

    /// How long it has been seen and since when, in a sentence or two, for
    /// its tooltip and details: "Seen for 2 min 13 s: it opened between
    /// 10:02:10 and 10:02:13." `time` formats a clock time.
    public func seenSummary(time format: (Date) -> String) -> String {
        let seen = "Seen for \(Format.timeSpan(seenFor.rounded(.down)))"
        var text: String
        if let after = timeline.first?.after {
            text = timeline.first?.isAfterGap == true
                ? "\(seen), since \(format(firstSeen)). It opened while the page wasn't watching, some time after \(format(after))."
                : "\(seen): it opened between \(format(after)) and \(format(firstSeen))."
        } else {
            text = "\(seen), since \(format(firstSeen)). It was already open at the page's first look, so it may be older."
        }
        if let closedBy {
            text += " Last seen at \(format(lastSeen)), gone by \(format(closedBy))."
        }
        return text
    }

    /// A length of time seen, rounded down so it never claims more watching
    /// than happened: "40 s", "2 min", "1 h 5 min", "2 days 3 h".
    public static func span(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let whole = Int(max(seconds, 0))
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return "\(whole / 60) min" }
        if whole < 86_400 {
            let minutes = whole % 3600 / 60
            return minutes == 0 ? "\(whole / 3600) h" : "\(whole / 3600) h \(minutes) min"
        }
        let days = whole / 86_400 == 1 ? "1 day" : "\(whole / 86_400) days"
        let hours = whole % 86_400 / 3600
        return hours == 0 ? days : "\(days) \(hours) h"
    }

    /// Notes a walk that found it again.
    fileprivate mutating func see(_ next: Connection, at date: Date, after previous: Date, isAfterGap: Bool) {
        if isAfterGap { add(ConnectionEvent(kind: .unwatched, time: date, after: previous, isAfterGap: true)) }
        let phase = ConnectionPhase(next)
        if phase != ConnectionPhase(connection) {
            add(ConnectionEvent(kind: .changed(phase), time: date, after: previous, isAfterGap: isAfterGap))
            if !next.kind.acceptsInbound {
                listeningSince = nil
            } else if !connection.kind.acceptsInbound {
                listeningSince = date
            }
        }
        connection = next
        lastSeen = date
    }

    /// Notes the walk that found it gone.
    fileprivate mutating func close(at date: Date, isAfterGap: Bool) {
        add(ConnectionEvent(kind: .closed, time: date, after: lastSeen, isAfterGap: isAfterGap))
        closedBy = date
    }

    private mutating func add(_ event: ConnectionEvent) {
        timeline.append(event)
        if timeline.count > ConnectionWatch.keptEvents {
            timeline.remove(at: 1)
            droppedEvents += 1
        }
    }
}

/// Follows sockets from one walk to the next: how long each has been seen,
/// what it was seen doing, and which closed.
///
/// A socket is its process (PID and start time), descriptor, protocol and
/// the kernel's handle for it, and it keeps its port once bound and its peer
/// once connected. A descriptor that a process closes and opens again comes
/// back with another handle, or on another port or peer if the handle is
/// reused too, so it reads as one socket closing and another opening. Only
/// walks are seen: a socket that opens and closes between two never shows.
public struct ConnectionWatch: Sendable {
    /// Closed sockets kept, at most.
    public static let keptClosed = 200
    /// Closed sockets are kept until they were last seen this long before the latest walk.
    public static let closedWindow: TimeInterval = 15 * 60
    /// How long a listener that was seen opening counts as new.
    public static let newListenerWindow: TimeInterval = 5 * 60
    /// Steps kept in a socket's timeline.
    static let keptEvents = 12

    /// Walks further apart than this have a gap between them: the page was
    /// closed, updates were paused or the Mac slept.
    public let maximumSpacing: TimeInterval

    /// The sockets the latest walk found, in its order.
    public private(set) var open: [ObservedConnection] = []
    /// Sockets that closed, the latest last: at most `keptClosed`, and
    /// none last seen more than `closedWindow` before the latest walk.
    public private(set) var closed: [ObservedConnection] = []
    public private(set) var firstWalk: Date?
    public private(set) var lastWalk: Date?
    /// The first walk since the latest gap: what this page has watched
    /// without a break.
    private var stretchStart: Date?
    private var nextID: ObservedConnection.ID = 1

    /// `maximumSpacing` should leave room for a slow walk at the page's
    /// cadence: 10 s for walks every 3 s.
    public init(maximumSpacing: TimeInterval = 10) {
        self.maximumSpacing = maximumSpacing
    }

    /// What can't change while a socket lives.
    private struct Key: Hashable {
        let process: ProcessIdentity
        let fd: Int32
        let transport: Connection.Transport
        let handle: UInt64

        init(_ connection: Connection) {
            process = connection.process
            fd = connection.id.fd
            transport = connection.transport
            handle = connection.id.socket
        }
    }

    /// Whether `next` can be `last` read again: a port, once bound, stays,
    /// and so does a peer once connected. Only a socket that hasn't got one
    /// yet gains it, and a wildcard bind can narrow to one address on connect.
    static func continues(_ last: Connection, as next: Connection) -> Bool {
        if let port = last.local.port {
            guard next.local.port == port else { return false }
            if !last.local.isWildcard, next.local.address != last.local.address { return false }
        }
        if let peer = last.remote, let nextPeer = next.remote, nextPeer != peer { return false }
        return true
    }

    /// Notes one walk's sockets, read at `date`.
    public mutating func observe(_ connections: [Connection], at date: Date) {
        let previous = lastWalk
        let isAfterGap = previous.map { date.timeIntervalSince($0) > maximumSpacing } ?? false
        if firstWalk == nil { firstWalk = date }
        if stretchStart == nil || isAfterGap { stretchStart = date }

        var waiting: [Key: ObservedConnection] = [:]
        waiting.reserveCapacity(open.count)
        var gone = Set<ObservedConnection.ID>()
        for socket in open {
            let key = Key(socket.connection)
            // Two sockets can't share a descriptor; should a walk ever say
            // so, the second is taken as closed rather than lost.
            if waiting[key] == nil { waiting[key] = socket } else { gone.insert(socket.id) }
        }

        var found: [ObservedConnection] = []
        found.reserveCapacity(connections.count)
        for connection in connections {
            let key = Key(connection)
            if var socket = waiting.removeValue(forKey: key), let previous {
                if Self.continues(socket.connection, as: connection) {
                    socket.see(connection, at: date, after: previous, isAfterGap: isAfterGap)
                    found.append(socket)
                    continue
                }
                gone.insert(socket.id)
            }
            found.append(ObservedConnection(id: nextID, connection: connection, at: date, after: previous, isAfterGap: isAfterGap))
            nextID += 1
        }
        for socket in waiting.values { gone.insert(socket.id) }

        for var socket in open where gone.contains(socket.id) {
            socket.close(at: date, isAfterGap: isAfterGap)
            closed.append(socket)
        }
        open = found
        lastWalk = date
        prune(at: date)
    }

    /// How far back an empty closed list can say it was watched: since the
    /// first walk after the latest gap, while that's within `closedWindow` of
    /// the latest walk; after that, the window itself, as older closings are
    /// let go. Either way only walks see a socket close. It changes once
    /// after each gap and once when the window fills, never with every walk.
    /// Nil before the first walk.
    public var closedCoverage: ClosedCoverage? {
        guard let stretchStart, let lastWalk else { return nil }
        return lastWalk.timeIntervalSince(stretchStart) <= Self.closedWindow ? .since(stretchStart) : .window
    }

    /// See `closedCoverage`.
    public enum ClosedCoverage: Hashable, Sendable {
        /// Walks have run without a break since this one, and every closing
        /// they saw is kept.
        case since(Date)
        /// Those seen in the last `closedWindow` are.
        case window
    }

    private mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.closedWindow)
        if closed.contains(where: { $0.lastSeen < cutoff }) { closed.removeAll { $0.lastSeen < cutoff } }
        if closed.count > Self.keptClosed { closed.removeFirst(closed.count - Self.keptClosed) }
    }
}
