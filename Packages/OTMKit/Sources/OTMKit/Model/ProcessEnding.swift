import Foundation

/// A successful signal delivery or accepted Quit request, not an inferred exit.
public struct ProcessEndAction: Sendable, Codable, Hashable {
    public let identity: ProcessIdentity
    public let path: String?
    /// Nil means the app accepted an ordinary Quit request, with no Unix signal sent.
    public let signal: Int32?

    public init(identity: ProcessIdentity, path: String?, signal: Int32?) {
        self.identity = identity
        self.path = path
        self.signal = signal
    }

    public var words: String {
        switch signal {
        case nil: "Quit requested by OpenTaskManager (End Task)"
        case 9: "Ended by OpenTaskManager (Force Quit)"
        case 15: "OpenTaskManager sent SIGTERM (End Task)"
        case let signal?: "OpenTaskManager sent \(LaunchExitStatus.signalName(signal) ?? "signal \(signal)")"
        }
    }
}

public extension HistoryEvent {
    static func endedByApp(time: Date, name: String, action: ProcessEndAction) -> HistoryEvent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(action)) ?? Data()
        return HistoryEvent(time: time, kind: .endedByApp, name: name, detail: String(decoding: data, as: UTF8.self))
    }

    var endAction: ProcessEndAction? {
        guard kind == .endedByApp else { return nil }
        return try? JSONDecoder().decode(ProcessEndAction.self, from: Data(detail.utf8))
    }
}

/// Independent sources stay separate: a hang report is evidence of a hang,
/// and an accepted Quit request is evidence of a request, never proof of a crash.
public struct ProcessEnding: Sendable, Codable, Equatable {
    public struct Evidence: Sendable, Codable, Equatable {
        public enum Source: String, Sendable, Codable { case diagnosticReport, openTaskManager, launchd }
        public let source: Source
        public let time: Date
        public let summary: String
        public let report: URL?

        public init(source: Source, time: Date, summary: String, report: URL? = nil) {
            self.source = source
            self.time = time
            self.summary = summary
            self.report = report
        }

        public func words(clock: (Date) -> String) -> String { summary + " at " + clock(time) }
    }

    /// Report times may follow the observed end by a little while.
    public static let reportMargin: TimeInterval = 120
    /// launchd's bulk history observes once a minute.
    public static let launchMargin: TimeInterval = 70
    public let lastSeen: Date
    public let ended: Date?
    public let evidence: [Evidence]

    public init(lifetime: ProcessLifetime, reports: [Evidence] = [], events: [HistoryEvent] = [],
                launchEvents: [LaunchHistoryEvent] = []) {
        lastSeen = lifetime.lastSeen
        ended = lifetime.ended
        let end = lifetime.ended ?? lifetime.lastSeen
        var found = reports
        for event in events {
            guard let action = event.endAction, action.identity == lifetime.identity,
                  action.path == nil || lifetime.path == nil || action.path == lifetime.path,
                  event.time >= lifetime.started, event.time <= end,
                  event.time >= lifetime.lastSeen.addingTimeInterval(-Self.launchMargin) else { continue }
            found.append(Evidence(source: .openTaskManager, time: event.time, summary: action.words))
        }
        for event in launchEvents {
            guard event.key.label == lifetime.jobLabel, event.kind == .exited, let exit = event.exit,
                  event.time >= lifetime.lastSeen, event.time <= end.addingTimeInterval(Self.launchMargin),
                  let since = event.since, since >= lifetime.started, since <= end,
                  event.pid == nil else { continue }
            if let identity = event.exitedIdentity {
                guard identity == lifetime.identity else { continue }
            } else {
                // Older observations need a preceding running PID for this job.
                let prior = launchEvents.last { $0.key == event.key && $0.time <= since && $0.time >= lifetime.started
                    && [.observed, .started, .restarted, .exited, .unloaded].contains($0.kind) }
                guard prior?.pid == lifetime.identity.pid else { continue }
            }
            let words: String
            switch exit {
            case .code(let code) where code < 0:
                let signal = -Int64(code)
                let name = Int32(exactly: signal).flatMap(LaunchExitStatus.signalName) ?? "signal \(signal)"
                words = "launchd reported terminated by \(name)"
            case .code(let code): words = "launchd reported exit code \(code)"
            case .reason: words = "launchd reported: \(exit.description)"
            }
            found.append(Evidence(source: .launchd, time: event.time, summary: words))
        }
        evidence = found.sorted { $0.time < $1.time }
    }

    public func words(clock: (Date) -> String) -> [String] {
        if !evidence.isEmpty { return evidence.map { $0.words(clock: clock) } }
        if let ended {
            return ["Ended between \(clock(lastSeen)) and \(clock(ended)); no crash report or exit status was found"]
        }
        return ["Last seen at \(clock(lastSeen)); no crash report or exit status was found"]
    }
}
