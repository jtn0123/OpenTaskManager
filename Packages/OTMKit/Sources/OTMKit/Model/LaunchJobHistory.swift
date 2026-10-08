import Foundation

/// History uses launchd's domain, not the folder the property list came from.
/// Two agents with the same label in this login session are the same job.
public struct LaunchHistoryKey: Sendable, Codable, Hashable {
    public let label: String
    public let domain: String

    public init(label: String, domain: String) {
        self.label = label
        self.domain = domain
    }

    public init(_ item: LaunchItem, uid: uid_t = getuid()) {
        self.init(label: item.label, domain: item.scope == .daemon ? "system" : "gui/\(uid)")
    }
}

public struct LaunchJobConfiguration: Sendable, Codable, Hashable {
    public let path: String
    public let modified: Date?
    public let program: String?
    public let arguments: [String]

    public init(_ item: LaunchItem) {
        path = item.plistPath
        modified = item.modified
        program = item.program
        arguments = item.arguments
    }
}

/// Times are observation times. `since` bounds a change, not its actual time.
public struct LaunchHistoryEvent: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case observed, started, exited, restarted, failed, crashed, restarting, loaded, unloaded, configuration
    }

    public let key: LaunchHistoryKey
    public let time: Date
    public let since: Date?
    public let kind: Kind
    public let pid: Int32?
    public let exit: LaunchExitStatus?
    public let detail: String
    public let configuration: LaunchJobConfiguration?

    public var id: String { "\(key.domain)/\(key.label)/\(time.timeIntervalSince1970)/\(kind.rawValue)" }

    public init(key: LaunchHistoryKey, time: Date, since: Date? = nil, kind: Kind, pid: Int32? = nil,
                exit: LaunchExitStatus? = nil, detail: String = "", configuration: LaunchJobConfiguration? = nil) {
        self.key = key
        self.time = time
        self.since = since
        self.kind = kind
        self.pid = pid
        self.exit = exit
        self.detail = detail
        self.configuration = configuration
    }

    public var words: String {
        switch kind {
        case .observed: detail
        case .started: "Started · PID \(pid.map(String.init) ?? "unknown")"
        case .exited: exit?.description ?? "Run ended · exit unknown"
        case .restarted: "Restarted · PID \(pid.map(String.init) ?? "unknown")"
        case .failed: "Became failed" + (exit.map { " · \($0.description)" } ?? "")
        case .crashed: "Became crashed" + (exit.map { " · \($0.description)" } ?? "")
        case .restarting: "Became restarting · 3 troubled restarts observed within 15 min"
        case .loaded: "Loaded"
        case .unloaded: "Unloaded · last exit unknown"
        case .configuration: detail.isEmpty ? "Configuration changed" : detail
        }
    }

    public func isRetained(at date: Date) -> Bool { time >= date.addingTimeInterval(-FlightRecorder.retention) }
}

public struct LaunchHistorySnapshot: Sendable, Hashable {
    public let key: LaunchHistoryKey
    public let time: Date
    public let job: LaunchJobStatus?
    public let instance: LaunchJobInstance?
    public let configuration: LaunchJobConfiguration?
    public let keepsAlive: Bool

    public init(key: LaunchHistoryKey, time: Date, job: LaunchJobStatus?, started: Date? = nil,
                configuration: LaunchJobConfiguration? = nil, keepsAlive: Bool = false) {
        self.key = key
        self.time = time
        self.keepsAlive = keepsAlive
        self.job = job
        instance = job?.pid.map { LaunchJobInstance(pid: $0, started: started) }
        self.configuration = configuration
    }
}

/// Only changes at two successful reads are events. The last exit can be
/// stale while a new PID runs, so a replacement alone never gets that code.
public enum LaunchHistoryDerivation {
    public static func events(from before: LaunchHistorySnapshot?, to after: LaunchHistorySnapshot, continuous: Bool = true)
        -> [LaunchHistoryEvent] {
        func event(_ kind: LaunchHistoryEvent.Kind, exit: LaunchExitStatus? = nil, detail: String = "") -> LaunchHistoryEvent {
            LaunchHistoryEvent(key: after.key, time: after.time, since: before?.time, kind: kind,
                               pid: after.job?.pid, exit: exit, detail: detail,
                               configuration: kind == .configuration ? after.configuration : nil)
        }
        guard let before else {
            let state = after.job?.pid.map { "First observed running · PID \($0)" }
                ?? (after.job == nil ? "First observed not loaded" : "First observed not running")
            let reported = after.job?.lastExit?.isFailure == true ? " · Last reported: \(after.job?.lastExit?.description ?? "unknown")" : ""
            var result = [event(.observed, exit: after.job?.lastExit, detail: state + reported)]
            if after.configuration != nil { result.append(event(.configuration, detail: "Configuration first read")) }
            return result
        }
        guard before.key == after.key, after.time > before.time else { return [] }
        var result: [LaunchHistoryEvent] = []
        if !continuous || after.time.timeIntervalSince(before.time) > LaunchHistoryCoverage.maximumReadGap {
            // Coverage carries the hole once per domain. A job gets an event
            // only if the state on either side differs; no run is invented.
            if !LaunchHistoryState(before).matches(after) {
                var detail = "Changed while not watched: was \(stateWords(before)), now \(stateWords(after))"
                if before.instance?.started != after.instance?.started, before.job?.pid == after.job?.pid, after.instance != nil {
                    detail += " · process start time changed"
                }
                result.append(event(.observed, exit: after.job?.lastExit, detail: detail))
                if after.job?.lastExit != before.job?.lastExit, after.job?.lastExit?.isFailure == true {
                    result.append(event(after.job?.lastExit?.crashSignal == nil ? .failed : .crashed, exit: after.job?.lastExit))
                }
            }
        } else {
            if (before.job == nil) != (after.job == nil) { result.append(event(after.job == nil ? .unloaded : .loaded)) }
            let replaced = before.instance.map { old in after.instance.map { !$0.isSame(as: old) } ?? false } ?? false
            let ended = before.instance != nil && after.instance == nil && after.job != nil
            let newExit = before.job != nil && after.job != nil
                && after.job?.lastExit != before.job?.lastExit && after.job?.lastExit != nil
            if replaced || ended || newExit {
                // For a replacement, a changed last-exit value is evidence of an
                // exit somewhere in the interval, not necessarily the watched run.
                let exit = ended || newExit ? after.job?.lastExit : nil
                result.append(event(.exited, exit: exit))
                if exit?.isFailure == true { result.append(event(exit?.crashSignal == nil ? .failed : .crashed, exit: exit)) }
            }
            if after.instance != nil && (before.instance == nil || replaced) { result.append(event(.started)) }
            if replaced { result.append(event(.restarted)) }
        }
        if let configuration = after.configuration, let old = before.configuration, configuration != old {
            result.append(event(.configuration))
        } else if after.configuration != nil && before.configuration == nil {
            result.append(event(.configuration, detail: "Configuration first read"))
        }
        return result
    }

    private static func stateWords(_ snapshot: LaunchHistorySnapshot) -> String {
        var words = snapshot.job?.pid.map { "running · PID \($0)" } ?? (snapshot.job == nil ? "not loaded" : "not running")
        if let exit = snapshot.job?.lastExit {
            if snapshot.job?.pid == nil {
                words += " · \(exit.description)"
            } else if exit.isFailure {
                words += " · Last reported: \(exit.description)"
            }
        }
        return words
    }
}

/// Keeps only the previous read and a bounded restart window for each job.
public struct LaunchHistoryTracker: Sendable {
    private var snapshots: [LaunchHistoryKey: LaunchHistorySnapshot] = [:]
    private var instances: [LaunchHistoryKey: LaunchJobInstance] = [:]
    private var restarts: [LaunchHistoryKey: [Date]] = [:]
    private var interrupted: Set<LaunchHistoryKey> = []
    private var configurations: [LaunchHistoryKey: LaunchJobConfiguration] = [:]

    public init() {}

    public mutating func noteConfiguration(_ configuration: LaunchJobConfiguration, for key: LaunchHistoryKey) {
        configurations[key] = configuration
        if let before = snapshots[key] {
            snapshots[key] = LaunchHistorySnapshot(key: key, time: before.time, job: before.job, started: before.instance?.started,
                                                   configuration: configuration, keepsAlive: before.keepsAlive)
        }
    }

    public mutating func interrupt(domain: String) {
        interrupted.formUnion(snapshots.keys.filter { $0.domain == domain })
    }

    /// A state row is rewritten at every watched change, so each job still
    /// held its saved state at its domain's last read: that read, not the
    /// older change, bounds anything that changed while the app was away.
    public mutating func seedStates(_ saved: [LaunchHistoryKey: LaunchHistoryState], lastReads: [String: Date] = [:]) {
        snapshots = saved.mapValues { state in
            let snapshot = state.snapshot
            guard let read = lastReads[state.key.domain], read > snapshot.time else { return snapshot }
            return LaunchHistorySnapshot(key: snapshot.key, time: read, job: snapshot.job, started: snapshot.instance?.started)
        }
        interrupted.formUnion(saved.keys)
    }

    public mutating func seedConfigurations(_ saved: [LaunchHistoryKey: LaunchJobConfiguration]) {
        configurations = saved
        for (key, configuration) in saved { noteConfiguration(configuration, for: key) }
    }

    public mutating func observe(_ reading: LaunchHistorySnapshot, continuous watched: Bool? = nil) -> [LaunchHistoryEvent] {
        // Keep a start time learned earlier if this cheaper read can't supply it.
        let previous = snapshots[reading.key]
        let started = reading.instance?.started ?? (previous?.job?.pid == reading.job?.pid ? previous?.instance?.started : nil)
        let snapshot = LaunchHistorySnapshot(key: reading.key, time: reading.time, job: reading.job, started: started,
                                             configuration: reading.configuration ?? previous?.configuration, keepsAlive: reading.keepsAlive)
        let key = snapshot.key
        let before = snapshots[key]
        if let before, snapshot.time <= before.time { return [] }
        let wasInterrupted = interrupted.remove(key) != nil
        let continuous = watched ?? (!wasInterrupted && (before.map {
            snapshot.time.timeIntervalSince($0.time) <= LaunchHistoryCoverage.maximumReadGap
        } ?? false))
        var events = LaunchHistoryDerivation.events(from: before, to: snapshot, continuous: continuous)
        if !continuous { instances[key] = nil; restarts[key] = nil }
        if snapshot.job == nil { instances[key] = nil; restarts[key] = nil }
        if let instance = snapshot.instance {
            if continuous, let old = instances[key], !instance.isSame(as: old) {
                if !events.contains(where: { $0.kind == .restarted }) {
                    events.append(LaunchHistoryEvent(key: key, time: snapshot.time, since: before?.time,
                                                    kind: .restarted, pid: instance.pid))
                }
                if snapshot.job?.lastExit?.isFailure == true || snapshot.keepsAlive {
                    var recent = restarts[key, default: []].filter { snapshot.time.timeIntervalSince($0) <= 900 }
                    recent.append(snapshot.time)
                    restarts[key] = Array(recent.suffix(20))
                    if recent.count == 3 {
                        events.append(LaunchHistoryEvent(key: key, time: snapshot.time, since: before?.time, kind: .restarting))
                    }
                }
            }
            instances[key] = instance
        }
        if let configuration = snapshot.configuration {
            if before == nil, let old = configurations[key], old != configuration {
                events.removeAll { $0.kind == .configuration }
                events.append(LaunchHistoryEvent(key: key, time: snapshot.time, kind: .configuration,
                                                detail: "Configuration changed since last read · time unknown", configuration: configuration))
            }
            if before == nil, configurations[key] == configuration { events.removeAll { $0.kind == .configuration } }
            configurations[key] = configuration
        }
        snapshots[key] = snapshot
        return events
    }
}
