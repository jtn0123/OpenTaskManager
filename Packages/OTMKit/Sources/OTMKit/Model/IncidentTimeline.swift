import Foundation

/// A fixed window never follows the live sampler or moves when new records arrive.
public struct IncidentWindow: Sendable, Codable, Hashable, Identifiable {
    public let start: Date
    public let end: Date
    public var id: Self { self }
    public static let minuteChoices = [1, 2, 5, 15]

    public init(from start: Date, to end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public init(at time: Date, minutes: Int = 2) {
        let radius = Double(min(max(minutes, 1), 15)) * 60
        self.init(from: time.addingTimeInterval(-radius), to: time.addingTimeInterval(radius))
    }

    public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    public var baseline: Self { Self(from: start.addingTimeInterval(-600), to: start) }
    public func contains(_ time: Date) -> Bool { time >= start && time <= end }
}

public enum IncidentLaneKind: String, Sendable, Codable, CaseIterable {
    case resources = "Resources", processes = "Processes", jobs = "Startup jobs", sockets = "Sockets", events = "Events"
}

/// Coverage belongs to a recorder, not to its matching rows. A cap cannot prove full coverage.
public struct IncidentCoverage: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable { case whole, partly, none }
    public let window: IncidentWindow
    public let spans: [LaunchHistoryInterval]
    public let cut: Bool
    public let note: String
    public let inferred: Bool

    public init(window: IncidentWindow, spans: [LaunchHistoryInterval], cut: Bool = false, note: String = "", inferred: Bool = false) {
        self.window = window
        self.spans = LaunchHistoryCoverage.merged(spans.compactMap {
            let start = max(window.start, $0.start)
            let end = min(window.end, $0.end)
            return start <= end ? LaunchHistoryInterval(start: start, end: end) : nil
        })
        self.cut = cut
        self.note = note
        self.inferred = inferred
    }

    public var state: State {
        guard !spans.isEmpty else { return cut ? .partly : .none }
        return !cut && !inferred && spans.count == 1 && spans[0].start <= window.start && spans[0].end >= window.end ? .whole : .partly
    }

    public var words: String {
        if inferred { return "Observer coverage not retained · recording spans and event sightings shown" }
        return switch state {
        case .whole: "Watched throughout"
        case .partly:
            spans.isEmpty ? "Coverage cut · watched spans not loaded"
                : "Partly watched · \(spans.count) watched spans" + (cut ? " · coverage cut" : "")
        case .none: "Not watched in this window"
        }
    }
}

/// Inspector destinations retain identities even when display names match.
public struct IncidentRow: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let time: Date
    public var title: String
    public var detail: String
    public var process: ProcessIdentity?
    public var lifetime: Int64?
    public var job: LaunchHistoryKey?
    public var socket: String?
    public var port: Int?
    public var transport: String?
    public var remoteAddress: String?
    public var kind: String
    public var user: String?
    public var ending: ProcessEnding?

    public init(id: String, time: Date, title: String, detail: String = "", process: ProcessIdentity? = nil,
                lifetime: Int64? = nil, job: LaunchHistoryKey? = nil, socket: String? = nil, port: Int? = nil,
                transport: String? = nil, remoteAddress: String? = nil, kind: String = "", user: String? = nil, ending: ProcessEnding? = nil) {
        self.id = id
        self.time = time
        self.title = title
        self.detail = detail
        self.process = process
        self.lifetime = lifetime
        self.job = job
        self.socket = socket
        self.port = port
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.kind = kind
        self.user = user
        self.ending = ending
    }
}

public struct IncidentLane: Sendable, Codable {
    public let kind: IncidentLaneKind
    public var rows: [IncidentRow]
    public let coverage: IncidentCoverage
    public let domains: [String: IncidentCoverage]
    public let cut: Bool
    public let note: String

    public init(kind: IncidentLaneKind, rows: [IncidentRow], coverage: IncidentCoverage,
                domains: [String: IncidentCoverage] = [:], limit: Int = 200, cut: Bool = false, note: String = "") {
        self.kind = kind
        self.rows = Array(rows.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }.prefix(max(limit, 0)))
        self.coverage = coverage
        self.domains = domains
        self.cut = cut || rows.count > limit
        self.note = note
    }
}

public struct IncidentSequence: Sendable, Codable, Identifiable {
    public let id: String
    public var label: String
    public var evidence: [IncidentRow]
}

public struct IncidentTimeline: Sendable, Codable {
    public let version: Int
    public let window: IncidentWindow
    public var lanes: [IncidentLane]
    public var sequences: [IncidentSequence]
    public let fixture: Bool

    public init(window: IncidentWindow, lanes: [IncidentLane], fixture: Bool = false) {
        version = 1
        self.window = window
        self.lanes = lanes
        self.fixture = fixture
        sequences = IncidentSequences.make(lanes)
    }

    /// Unknown start times never turn a reused PID into an identity join.
    public static func lifetime(for identity: ProcessIdentity?, in lifetimes: [ProcessLifetime]) -> ProcessLifetime? {
        guard let identity, identity.startTime != nil else { return nil }
        return lifetimes.first { $0.identity == identity }
    }
}

public enum IncidentSequences {
    public static func make(_ lanes: [IncidentLane]) -> [IncidentSequence] {
        let rows = lanes.flatMap(\.rows)
        var result: [IncidentSequence] = []
        let restarts = Dictionary(grouping: rows.filter { $0.kind == "restarted" && $0.job != nil }, by: \.job)
        for (key, evidence) in restarts.sorted(by: { ($0.key?.label ?? "") < ($1.key?.label ?? "") }) {
            guard let key else { continue }
            result.append(IncidentSequence(id: "restart/\(key.domain)/\(key.label)",
                                           label: "\(key.label) restarted \(evidence.count) \(evidence.count == 1 ? "time" : "times")"
                                               + " · \(key.domain)",
                                           evidence: evidence))
        }
        let listeners = rows.filter { $0.kind == "listener" }
        for ended in rows where ended.kind == "ended" && ended.process?.startTime != nil {
            // The old socket must belong to this exact lifetime; a name or PID alone proves no shared port.
            let ports = rows.filter { $0.process == ended.process && $0.socket != nil && $0.port != nil }
            if let listener = listeners.first(where: { new in
                new.time > ended.time && ports.contains { $0.port == new.port && $0.transport == new.transport }
            }), let socket = ports.first(where: { $0.port == listener.port && $0.transport == listener.transport }) {
                result.append(IncidentSequence(id: "listener/\(ended.id)/\(listener.id)",
                    label: "Ended then a new listener on the same port \(listener.port ?? 0)", evidence: [socket, ended, listener]))
            }
        }
        if let cpu = rows.first(where: { $0.kind == "cpuRose" }), let busiest = rows.first(where: { $0.kind == "busiest" }) {
            result.append(IncidentSequence(id: "cpu", label: "CPU rose while \(busiest.title) was busiest", evidence: [cpu, busiest]))
        }
        return result.sorted { ($0.evidence.last?.time ?? .distantPast) < ($1.evidence.last?.time ?? .distantPast) }
    }
}

extension HistoryEvent.Kind {
    var incidentWords: String {
        switch self {
        case .appLaunched: "App launched"
        case .appQuit: "App quit"
        case .endedByApp: "Ending action"
        case .processStarted: "Busy process started"
        case .processExited: "Busy process exited"
        case .networkChanged: "Network changed"
        case .sleep: "Sleep"
        case .wake: "Wake"
        case .spike: "Resource spike"
        }
    }
}
