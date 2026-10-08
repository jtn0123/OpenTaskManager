import Foundation

/// Metadata belongs to the process identity, never to a PID that may have been reused.
public struct ConnectionProcess: Sendable, Codable, Equatable {
    public let name: String
    public let path: String?
    public let user: String

    public init(name: String, path: String?, user: String) {
        self.name = name
        self.path = path
        self.user = user
    }
}

/// One observed lifetime. A stopped watch never supplies a time of closure.
public struct ConnectionLifetime: Sendable, Codable, Identifiable {
    public enum Ending: String, Sendable, Codable {
        case closed, stopped, watching
    }

    public let id: String
    public var socket: ObservedConnection
    public let process: ConnectionProcess
    public var ending: Ending
    public var closedBy: Date?
    public var states: [TCPState]

    public init(id: String = UUID().uuidString, socket: ObservedConnection, process: ConnectionProcess,
                ending: Ending = .watching, closedBy: Date? = nil, states: [TCPState] = []) {
        self.id = id
        self.socket = socket
        self.process = process
        self.ending = ending
        self.closedBy = closedBy
        self.states = states
    }

    public func endedWords(time format: (Date) -> String) -> String {
        if ending == .closed, let closedBy {
            return "Closed between \(format(socket.lastSeen)) and \(format(closedBy))"
        }
        return ending == .watching ? "Still open at the last observed walk" : "Still open when watching stopped"
    }

    /// Numeric searches match whole ports or PIDs; text searches include the stored service name.
    public func matches(_ search: String) -> Bool {
        let query = Self.normalized(search)
        guard !query.isEmpty else { return true }
        let connection = socket.connection
        if let number = Int(query) {
            return Int(connection.pid) == number || connection.local.port == number || connection.remote?.port == number
        }
        return searchText.contains(query)
    }

    /// Stored beside the payload so a search needn't decode the week's entire timelines.
    public var searchText: String {
        let connection = socket.connection
        let fields = [process.name, process.path, connection.processName, connection.local.address,
                      connection.remote?.address, connection.local.formatted, connection.remote?.formatted, connection.service?.name]
        return Self.normalized(fields.compactMap { $0 }.joined(separator: "\n"))
    }

    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct ConnectionHistoryBatch: Sendable {
    public var rows: [ConnectionLifetime] = []
    public var active: Set<String> = []
    public var interval: ConnectionWatchInterval?
    public init() {}
}

/// Derives writes from the existing watch. Changes accumulate until a minute bump or an end, not one write per state.
public struct ConnectionHistoryTracker: Sendable {
    private struct Tracked: Sendable {
        var row: ConnectionLifetime
        var written: Date
    }
    private var tracked: [UInt64: Tracked] = [:]
    private var coverage = ConnectionCoverageTracker()
    public init() {}

    public mutating func observe(_ watch: ConnectionWatch, at time: Date, spacing: TimeInterval,
                                 hidden: Int, unreadable: Set<Int32> = [], processes: [ProcessIdentity: ConnectionProcess] = [:])
        -> ConnectionHistoryBatch {
        var batch = ConnectionHistoryBatch()
        let interval = coverage.observe(at: time, spacing: spacing, hidden: hidden)
        if interval.id != coverageID, interval.start == time { batch = stopRows() }
        coverageID = interval.id
        batch.interval = interval
        let found = Set(watch.open.map(\.id))
        for id in Array(tracked.keys) where !found.contains(id) {
            guard var entry = tracked.removeValue(forKey: id) else { continue }
            if !unreadable.contains(entry.row.socket.connection.pid) {
                entry.row.ending = .closed
                entry.row.closedBy = time
                entry.row.socket = entry.row.socket.ending(at: time)
            }
            if entry.row.ending != .closed { entry.row.ending = .stopped }
            batch.rows.append(entry.row)
        }
        for socket in watch.open {
            var entry = tracked[socket.id] ?? Tracked(row: ConnectionLifetime(
                socket: socket.segment(since: time), process: processes[socket.connection.process]
                    ?? ConnectionProcess(name: socket.connection.processName, path: nil, user: "Not recorded")
            ), written: .distantPast)
            entry.row.socket = entry.row.socket.observing(socket.connection, at: time)
            if let state = socket.connection.tcpState, !entry.row.states.contains(state) { entry.row.states.append(state) }
            if time.timeIntervalSince(entry.written) >= 60 {
                batch.rows.append(entry.row)
                batch.active.insert(entry.row.id)
                entry.written = time
            }
            tracked[socket.id] = entry
        }
        return batch
    }

    private var coverageID: String?

    public mutating func stop() -> ConnectionHistoryBatch {
        coverage.stop()
        coverageID = nil
        return stopRows()
    }

    private mutating func stopRows() -> ConnectionHistoryBatch {
        var batch = ConnectionHistoryBatch()
        batch.rows = tracked.values.map { entry in
            var row = entry.row
            row.ending = .stopped
            return row
        }
        tracked.removeAll()
        return batch
    }
}

/// The same order used by the database cap, exposed as a pure rule for tests and exports.
public enum ConnectionHistoryRetention {
    public static let rowLimit = 50_000

    public static func retained(_ rows: [ConnectionLifetime], active: Set<String>, before cutoff: Date,
                                limit: Int = rowLimit) -> [ConnectionLifetime] {
        let eligible = rows.filter { $0.socket.lastSeen >= cutoff }
        let ordered = eligible.sorted {
            let left = active.contains($0.id)
            let right = active.contains($1.id)
            if left != right { return left }
            if $0.socket.lastSeen != $1.socket.lastSeen { return $0.socket.lastSeen > $1.socket.lastSeen }
            return $0.id > $1.id
        }
        return Array(ordered.prefix(max(0, limit)))
    }
}

/// Lifetimes and coverage from the same database snapshot, including for CLI JSON.
public struct ConnectionHistoryResult: Sendable, Codable {
    public let coverage: ConnectionHistoryCoverage
    public let lifetimes: [ConnectionLifetime]

    public init(coverage: ConnectionHistoryCoverage, lifetimes: [ConnectionLifetime]) {
        self.coverage = coverage
        self.lifetimes = lifetimes
    }
}
