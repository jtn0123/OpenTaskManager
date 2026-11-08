import Foundation

/// Reads signatures only for paths holding listeners, once per path for this watch, including failed reads.
public struct ListenerIdentityReader: Sendable {
    private var signatures: [String: CodeSignature] = [:]

    public init() {}

    public struct Reading: Sendable {
        public let listeners: [ListenerObservation]
        public let unreadableProcesses: Int
    }

    public mutating func read(_ snapshot: ConnectionSnapshot,
                              processes: [ProcessIdentity: ConnectionProcess]? = nil) -> Reading {
        let metadata = processes ?? snapshot.processes
        var unreadable = snapshot.unreadablePIDs
        var seen = Set<ListenerIdentity>()
        var listeners: [ListenerObservation] = []
        for connection in snapshot.connections where connection.kind.acceptsInbound {
            guard let path = metadata[connection.process]?.path, !path.isEmpty else {
                unreadable.insert(connection.pid)
                continue
            }
            let signature = signatures[path] ?? CodeSigning.signature(atPath: path)
            signatures[path] = signature
            let executable = ListenerExecutable(path: path, teamIdentifier: signature.teamIdentifier,
                                                signingIdentifier: signature.identifier)
            guard let identity = ListenerIdentity(connection: connection, executable: executable), seen.insert(identity).inserted else {
                continue
            }
            listeners.append(ListenerObservation(identity: identity, connection: connection))
        }
        return Reading(listeners: listeners, unreadableProcesses: max(snapshot.hiddenProcesses, unreadable.count))
    }
}
