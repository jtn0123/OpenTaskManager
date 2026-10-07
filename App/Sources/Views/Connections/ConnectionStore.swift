import AppKit
import Observation
import OTMKit

/// The Connections page's sockets, refreshed on their own slow cadence.
///
/// Walking every process's descriptors costs a few thousand system calls, so
/// it runs off the main actor every few seconds, and only while the page is
/// on screen: the view's `.task` drives `run`, and SwiftUI cancels it when
/// the page goes away.
@Observable
@MainActor
final class ConnectionStore {
    static let refreshInterval: Duration = .seconds(3)

    private(set) var rows: [ConnectionRow] = []
    private(set) var summary = ConnectionSummary()
    private(set) var hiddenProcesses = 0
    /// How long the last walk took.
    private(set) var walkDuration: TimeInterval = 0
    private(set) var hasLoaded = false

    /// Refreshes until cancelled. While updates are paused it loads once, so
    /// the page isn't empty, then leaves the data frozen like the other pages.
    func run(model: AppModel) async {
        guard !model.isPaused else {
            if !hasLoaded { await refresh(model) }
            return
        }
        while !Task.isCancelled {
            await refresh(model)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    private func refresh(_ model: AppModel) async {
        let snapshot = await Task.detached(priority: .utility) { ConnectionSampler.sample() }.value
        guard !Task.isCancelled else { return }
        apply(snapshot, model: model)
    }

    private func apply(_ snapshot: ConnectionSnapshot, model: AppModel) {
        // Names and icons come from the main sampler's latest snapshot, so an
        // app reads "Safari" rather than its executable's short name.
        var processes: [Int32: ProcessSample] = [:]
        for process in model.snapshot?.processes ?? [] { processes[process.pid] = process }
        rows = snapshot.connections.map { connection in
            guard let process = processes[connection.pid] else {
                return ConnectionRow(connection: connection, processName: connection.processName, icon: IconCache.generic)
            }
            return ConnectionRow(
                connection: connection,
                processName: model.displayName(for: process),
                icon: IconCache.icon(for: process, app: model.regularApps[process.pid])
            )
        }
        summary = ConnectionSummary(snapshot.connections)
        hiddenProcesses = snapshot.hiddenProcesses
        walkDuration = snapshot.duration
        hasLoaded = true
    }
}

/// One socket as the table shows it, with sort keys for each column.
struct ConnectionRow: Identifiable {
    let connection: Connection
    let processName: String
    let icon: NSImage

    var id: Connection.ID { connection.id }
    var pid: Int32 { connection.pid }
    var protocolName: String { "\(connection.transport.rawValue) \(connection.family.rawValue)" }
    /// Local endpoints sort by port, which is what people scan for.
    var localOrder: PortOrder { PortOrder(port: connection.local.port ?? 0, address: connection.local.address) }
    var remoteOrder: String { connection.remote?.formatted ?? "" }
    var stateOrder: Int { connection.kind.rank }
    var scopeOrder: Int { AddressScope.allCases.firstIndex(of: connection.scope) ?? 0 }

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
