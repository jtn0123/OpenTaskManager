import Foundation

/// The executable's identity comes from disk, so a new PID doesn't look like a new listener.
public struct ListenerExecutable: Sendable, Hashable, Codable {
    public let path: String
    public let teamIdentifier: String?
    public let signingIdentifier: String?

    public init(path: String, teamIdentifier: String? = nil, signingIdentifier: String? = nil) {
        self.path = path
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }
}

/// Loopback and wildcard addresses share a scope across IPv4 and IPv6; other binds keep their address.
public enum ListenerBindScope: Sendable, Hashable, Codable {
    case loopback, allInterfaces, address(String)

    public init(_ endpoint: Endpoint) {
        switch endpoint.scope {
        case .loopback: self = .loopback
        case .allInterfaces: self = .allInterfaces
        default: self = .address(endpoint.address.lowercased())
        }
    }

    public var label: String {
        switch self {
        case .loopback: "Loopback"
        case .allInterfaces: "All interfaces"
        case let .address(address): address
        }
    }
}

public struct ListenerIdentity: Sendable, Hashable, Codable {
    /// macOS's default ephemeral range (`net.inet.ip.portrange`): a port here was most
    /// likely picked by the system, and is picked again at the next launch.
    public static let systemAssignedPorts = 49_152...65_535

    public let executable: ListenerExecutable
    public let transport: Connection.Transport
    /// Nil for a port in `systemAssignedPorts`, so a new random port at each launch isn't a new listener.
    public let port: Int?
    public let scope: ListenerBindScope

    public init(executable: ListenerExecutable, transport: Connection.Transport, port: Int, scope: ListenerBindScope) {
        self.executable = executable
        self.transport = transport
        self.port = Self.systemAssignedPorts.contains(port) ? nil : port
        self.scope = scope
    }

    /// "port 8080", or the port last seen for one the system assigned.
    public func portLabel(seen: Int?) -> String {
        if let port { return "port \(port)" }
        return seen.map { "system-assigned port (\($0) when seen)" } ?? "a system-assigned port"
    }

    public init?(connection: Connection, executable: ListenerExecutable) {
        guard connection.kind.acceptsInbound, let port = connection.local.port else { return nil }
        self.init(executable: executable, transport: connection.transport, port: port, scope: ListenerBindScope(connection.local))
    }
}

/// One socket is retained as evidence, even if the listener stops before its change is reviewed.
public struct ListenerObservation: Sendable, Equatable, Codable {
    public let identity: ListenerIdentity
    public let connection: Connection

    public init(identity: ListenerIdentity, connection: Connection) {
        self.identity = identity
        self.connection = connection
    }
}

public struct ListenerChange: Sendable, Equatable, Codable, Identifiable {
    public enum Reason: String, Sendable, Codable {
        case newExecutable, newPort, scopeWidened, portOwnerChanged, bindChanged

        public var label: String {
            switch self {
            case .newExecutable: "New executable listening"
            case .newPort: "Reviewed executable on a new port"
            case .scopeWidened: "Now listening on all interfaces"
            case .portOwnerChanged: "Different executable on a reviewed port"
            case .bindChanged: "Listening on a different address"
            }
        }
    }

    public let listener: ListenerObservation
    public let reasons: [Reason]
    public let previousHolders: [String]
    public let detectedAt: Date
    public var id: ListenerIdentity { listener.identity }

    public init(listener: ListenerObservation, reasons: [Reason], previousHolders: [String] = [], detectedAt: Date) {
        self.listener = listener
        self.reasons = reasons
        self.previousHolders = previousHolders
        self.detectedAt = detectedAt
    }
}

/// A review adds identities, rather than forgetting listeners that happen to be absent at that walk.
public struct ListenerBaseline: Sendable, Equatable, Codable {
    public let setAt: Date
    public private(set) var reviewedAt: Date
    public private(set) var listeners: Set<ListenerIdentity>

    public init(listeners: Set<ListenerIdentity>, at time: Date) {
        self.listeners = listeners
        setAt = time
        reviewedAt = time
    }

    public mutating func accept(_ listeners: Set<ListenerIdentity>, at time: Date) {
        self.listeners.formUnion(listeners)
        reviewedAt = time
    }
}

/// Both the baseline and unaccepted changes survive a restart, independently of history retention.
public struct ListenerReview: Sendable, Equatable, Codable {
    public private(set) var baseline: ListenerBaseline
    public private(set) var changes: [ListenerChange]

    public init(baseline: ListenerBaseline, changes: [ListenerChange] = []) {
        self.baseline = baseline
        self.changes = changes
    }

    public mutating func record(_ confirmed: [ListenerObservation], at time: Date) {
        let pending = Set(changes.map(\.id))
        changes += ListenerChangeRules.changes(confirmed.filter { !pending.contains($0.identity) },
                                              baseline: baseline.listeners, at: time)
    }

    public mutating func accept(_ identities: Set<ListenerIdentity>, at time: Date) {
        let accepted = Set(changes.filter { identities.contains($0.id) }.map(\.id))
        guard !accepted.isEmpty else { return }
        baseline.accept(accepted, at: time)
        changes.removeAll { accepted.contains($0.id) }
    }
}

public enum ListenerChangeRules {
    private struct Port: Hashable {
        let transport: Connection.Transport
        let number: Int?
        init(_ identity: ListenerIdentity) { transport = identity.transport; number = identity.port }
    }

    /// Compare only observed identities. Missing sockets never imply that unreadable processes have none.
    public static func changes(_ listeners: [ListenerObservation], baseline: Set<ListenerIdentity>, at time: Date) -> [ListenerChange] {
        let executables = Dictionary(grouping: baseline, by: \.executable)
        let ports = Dictionary(grouping: baseline, by: Port.init)
        var seen = Set<ListenerIdentity>()
        return listeners.compactMap { listener in
            let identity = listener.identity
            guard !baseline.contains(identity), seen.insert(identity).inserted else { return nil }
            let sameExecutable = executables[identity.executable] ?? []
            let samePort = sameExecutable.filter { $0.transport == identity.transport && $0.port == identity.port }
            var reasons: [ListenerChange.Reason] = []
            if sameExecutable.isEmpty {
                reasons.append(.newExecutable)
            } else if samePort.isEmpty {
                reasons.append(.newPort)
            } else if identity.scope == .allInterfaces && samePort.allSatisfy({ $0.scope == .loopback }) {
                reasons.append(.scopeWidened)
            } else {
                reasons.append(.bindChanged)
            }
            // Two executables on system-assigned ports never held the same port.
            let holders = identity.port == nil ? [] : ports[Port(identity), default: []].filter { $0.executable != identity.executable }
            if !holders.isEmpty { reasons.append(.portOwnerChanged) }
            return ListenerChange(listener: listener, reasons: reasons,
                                  previousHolders: Set(holders.map(\.executable.path)).sorted(), detectedAt: time)
        }
    }
}

/// Two consecutive walks of the stable identity settle a listener; gaps and unreadable walks break that pair.
public struct ListenerDebounce: Sendable {
    private var previous = Set<ListenerIdentity>()
    private var lastWalk: Date?

    public init() {}

    public mutating func observe(_ listeners: [ListenerObservation], at time: Date,
                                 maximumSpacing: TimeInterval) -> [ListenerObservation] {
        if let lastWalk, time.timeIntervalSince(lastWalk) > maximumSpacing || time < lastWalk { previous.removeAll() }
        let confirmed = listeners.filter { previous.contains($0.identity) }
        previous = Set(listeners.map(\.identity))
        lastWalk = time
        return confirmed
    }

    public mutating func stop() { previous.removeAll(); lastWalk = nil }
}
