import AppKit
import Observation
import OTMKit

/// The Connections page's sockets, refreshed on their own slow cadence.
///
/// Walking every process's descriptors costs a few thousand system calls, so
/// it runs off the main actor every few seconds, and only while the page is
/// on screen: the view's `.task` drives `run`, and SwiftUI cancels it when
/// the page goes away. Each walk is noted in a `ConnectionWatch`, off the
/// main actor with the walk, for how long each socket has been seen and
/// which closed. The store lasts the session, so that survives a visit to
/// another page; the time away shows as a gap the page didn't watch.
@Observable
@MainActor
final class ConnectionStore {
    static let refreshInterval: Duration = .seconds(3)
    static let shared = ConnectionStore()

    /// The open sockets, as the latest walk found them.
    private(set) var rows: [ConnectionRow] = []
    /// Sockets seen closing, the latest first: the last
    /// `ConnectionWatch.keptClosed`, from its `closedWindow` at most.
    private(set) var closedRows: [ConnectionRow] = []
    private(set) var summary = ConnectionSummary()
    private(set) var hiddenProcesses = 0
    /// How long the last walk took.
    private(set) var walkDuration: TimeInterval = 0
    private(set) var hasLoaded = false
    /// The first walk this session: as far back as "seen for" can reach.
    private(set) var watchingSince: Date?

    @ObservationIgnored private var watch = ConnectionWatch()
    /// Each socket's process name and icon as they were while it was open,
    /// for its row once it has closed and its process may be gone.
    @ObservationIgnored private var looks: [ObservedConnection.ID: ConnectionRow.Look] = [:]

    /// Refreshes until cancelled. While updates are paused it loads once as
    /// the page opens, so the page isn't empty or stale, then leaves the data
    /// frozen like the other pages.
    func run(model: AppModel, opening: Bool) async {
        guard !model.isPaused else {
            if opening || !hasLoaded { await refresh(model) }
            return
        }
        while !Task.isCancelled {
            await refresh(model)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// The socket, open or closed.
    func row(_ id: ObservedConnection.ID) -> ConnectionRow? {
        rows.first { $0.id == id } ?? closedRows.first { $0.id == id }
    }

    private func refresh(_ model: AppModel) async {
        let watch = watch
        let (snapshot, next) = await Task.detached(priority: .utility) {
            let snapshot = ConnectionSampler.sample()
            var next = watch
            next.observe(snapshot.connections, at: snapshot.time)
            return (snapshot, next)
        }.value
        guard !Task.isCancelled else { return }
        self.watch = next
        apply(snapshot, model: model)
    }

    private func apply(_ snapshot: ConnectionSnapshot, model: AppModel) {
        // Names and icons come from the main sampler's latest snapshot, so an
        // app reads "Safari" rather than its executable's short name.
        var processes: [Int32: ProcessSample] = [:]
        for process in model.snapshot?.processes ?? [] { processes[process.pid] = process }
        var looks: [ObservedConnection.ID: ConnectionRow.Look] = [:]
        looks.reserveCapacity(watch.open.count + watch.closed.count)
        rows = watch.open.map { socket in
            let look = Self.look(for: socket.connection, in: processes, model: model)
            looks[socket.id] = look
            return ConnectionRow(socket: socket, look: look, at: snapshot.time, processRunning: true)
        }
        closedRows = watch.closed.reversed().map { socket in
            let look = self.looks[socket.id] ?? ConnectionRow.Look(name: socket.connection.processName, icon: IconCache.generic)
            looks[socket.id] = look
            let running = processes[socket.connection.pid].map { $0.identity == socket.connection.process } ?? false
            return ConnectionRow(socket: socket, look: look, at: snapshot.time, processRunning: running)
        }
        self.looks = looks
        summary = ConnectionSummary(snapshot.connections)
        hiddenProcesses = snapshot.hiddenProcesses
        walkDuration = snapshot.duration
        watchingSince = watch.firstWalk
        hasLoaded = true
    }

    private static func look(for connection: Connection, in processes: [Int32: ProcessSample], model: AppModel) -> ConnectionRow.Look {
        // A PID the process list has for another process (reused since) gets no name or icon from it.
        guard let process = processes[connection.pid],
              process.startTime == nil || connection.processStart == nil || process.startTime == connection.processStart
        else { return ConnectionRow.Look(name: connection.processName, icon: IconCache.generic) }
        return ConnectionRow.Look(name: model.displayName(for: process),
                                  icon: IconCache.icon(for: process, app: model.regularApps[process.pid]))
    }
}

/// One socket as the table shows it, with sort keys for each column.
struct ConnectionRow: Identifiable {
    /// The process's name and icon.
    struct Look {
        let name: String
        let icon: NSImage
    }

    let socket: ObservedConnection
    let processName: String
    let icon: NSImage
    /// The walk the row is as of, which its "seen for" and "closed ago" count to.
    let now: Date
    /// Seen starting to listen a short while ago (`ConnectionWatch.newListenerWindow`).
    let isNewListener: Bool
    /// The process that held it still runs; always, while the socket is open.
    let processRunning: Bool

    init(socket: ObservedConnection, look: Look, at now: Date, processRunning: Bool) {
        self.socket = socket
        processName = look.name
        icon = look.icon
        self.now = now
        isNewListener = socket.isNewListener(at: now)
        self.processRunning = processRunning
    }

    var connection: Connection { socket.connection }
    var id: ObservedConnection.ID { socket.id }
    var pid: Int32 { connection.pid }
    var isOpen: Bool { socket.isOpen }
    var protocolName: String { "\(connection.transport.rawValue) \(connection.family.rawValue)" }
    /// Local endpoints sort by port, which is what people scan for.
    var localOrder: PortOrder { PortOrder(port: connection.local.port ?? 0, address: connection.local.address) }
    var remoteOrder: String { connection.remote?.formatted ?? "" }
    /// Open sockets by state, servers first; closed ones, which all say
    /// "Closed", by how long ago they went, the latest first.
    var stateOrder: Double {
        socket.closedBy.map { 100 + now.timeIntervalSince($0) } ?? Double(connection.kind.rank)
    }
    var scopeOrder: Int { AddressScope.allCases.firstIndex(of: connection.scope) ?? 0 }
    var seenForOrder: TimeInterval { socket.seenFor }

    /// How long ago it closed, nil while it's open.
    var closedAgo: TimeInterval? { socket.closedBy.map { now.timeIntervalSince($0) } }

    /// Matches process name, service name or part of either address; a
    /// number also matches the PID or a port exactly (so 443 doesn't find 4430).
    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if let number = Int(query),
           Int(pid) == number || connection.local.port == number || connection.remote?.port == number {
            return true
        }
        let fields = [processName, connection.local.address, connection.remote?.address, connection.service?.name]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

struct PortOrder: Comparable {
    let port: Int
    let address: String

    static func < (lhs: PortOrder, rhs: PortOrder) -> Bool {
        (lhs.port, lhs.address) < (rhs.port, rhs.address)
    }
}
