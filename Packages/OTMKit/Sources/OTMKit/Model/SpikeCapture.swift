import Foundation

/// A process in one update's top list, by PID and start time.
public struct SpikeProcess: Sendable, Equatable {
    public var name: String
    public var pid: Int32
    public var startTime: Date?
    /// CPU: percent of one core (100 = one core). Memory: footprint in
    /// bytes. Disk: bytes per second read and written.
    public var value: Double

    public init(name: String, pid: Int32, startTime: Date?, value: Double) {
        self.name = name
        self.pid = pid
        self.startTime = startTime
        self.value = value
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }

    static let empty = SpikeProcess(name: "", pid: 0, startTime: nil, value: 0)
}

/// One update in a capture: its figures and its busiest processes, highest first.
public struct SpikeMoment: Sendable, Equatable {
    public let sample: SpikeSample
    public let topCPU: [SpikeProcess]
    public let topMemory: [SpikeProcess]
    public let topDisk: [SpikeProcess]

    public init(sample: SpikeSample, topCPU: [SpikeProcess] = [], topMemory: [SpikeProcess] = [], topDisk: [SpikeProcess] = []) {
        self.sample = sample
        self.topCPU = topCPU
        self.topMemory = topMemory
        self.topDisk = topDisk
    }
}

/// What `SpikeRecorder` hands off once a capture's window has passed: the
/// updates from a couple of minutes before the first trigger to a minute
/// after it, the triggers, and when the first one's condition ended. Turned
/// into a recording file (`recording`) off the main actor.
public struct SpikeCapture: Sendable, Equatable {
    /// Never empty; the first started the capture.
    public let triggers: [SpikeTrigger]
    /// Oldest first, never empty.
    public let moments: [SpikeMoment]
    /// When the first trigger's condition was found to have ended, if it
    /// did within the capture.
    public let cleared: Date?
    /// For the share of the whole CPU a process's time is.
    public let logicalCores: Int

    public init(triggers: [SpikeTrigger], moments: [SpikeMoment], cleared: Date?, logicalCores: Int) {
        precondition(!triggers.isEmpty && !moments.isEmpty, "A capture has a trigger and an update")
        self.triggers = triggers
        self.moments = moments
        self.cleared = cleared
        self.logicalCores = max(logicalCores, 1)
    }

    /// The start of the first update's interval.
    public var start: Date {
        let first = moments[0].sample
        return first.time.addingTimeInterval(-first.interval)
    }

    /// The end of the last update.
    public var end: Date { moments[moments.count - 1].sample.time }

    /// Seconds each update covers: the middle of the updates' intervals,
    /// to a tenth of a second.
    public var recordSeconds: TimeInterval {
        let intervals = moments.map(\.sample.interval).filter { $0 > 0 && $0.isFinite }.sorted()
        guard !intervals.isEmpty else { return 1 }
        return max((intervals[intervals.count / 2] * 10).rounded() / 10, 0.1)
    }

    /// The first trigger's condition from when it began to when it ended,
    /// within the capture, with its figure over that stretch and the
    /// processes that used the most of its resource.
    public var incident: SpikeIncident {
        let primary = triggers[0]
        let from = max(primary.since, start)
        let to = cleared.map { min(max($0, from), end) } ?? end
        var window = moments.filter { $0.sample.time > from && $0.sample.time <= to }
        if window.isEmpty { window = moments.filter { $0.sample.time >= primary.time }.prefix(1).map { $0 } }
        if window.isEmpty { window = [moments[moments.count - 1]] }
        var covered = 0.0
        var sum = 0.0
        var peak = -Double.infinity
        var worst: Double?
        for moment in window {
            let figure = Self.figure(primary.kind, moment.sample)
            covered += moment.sample.interval
            sum += figure * moment.sample.interval
            peak = max(peak, figure)
            if primary.kind == .memory { worst = max(worst ?? 0, Self.ordinal(moment.sample.pressure)) }
            if primary.kind == .thermal { worst = max(worst ?? 0, SpikeTriggers.ordinal(moment.sample.thermal)) }
        }
        let average = covered > 0 ? sum / covered : peak
        return SpikeIncident(triggers: triggers, start: from, end: to, ongoing: cleared == nil, average: average, peak: peak,
                             level: worst.map { Self.level(primary.kind, ordinal: $0) } ?? primary.level,
                             contributors: Self.contributors(window, measure: Self.measure(primary.kind), logicalCores: logicalCores,
                                                             kept: SpikeRecorder.contributorsKept))
    }

    /// The capture as a recording file: a record per update, the busiest
    /// apps by name in each (same-named processes added up), `events` from
    /// within it with an event for each trigger, and the incident block. The
    /// session's note is the incident's headline.
    public func recording(machine: RecordingMachine, generator: String, exported: Date, events: [HistoryEvent] = []) -> RecordingFile {
        let incident = incident
        let records = moments.map { moment in
            HistoryRecord(time: moment.sample.time, values: moment.sample.values, topCPU: Self.apps(moment.topCPU),
                          topMemory: Self.apps(moment.topMemory))
        }
        let session = RecordingSession(start: start, end: end, note: incident.headline)
        var kept = events.filter { $0.time >= start && $0.time <= end }
        let seen = Set(kept.map(\.id))
        kept += triggers.map(\.event).filter { !seen.contains($0.id) }
        return RecordingFile(session: session, machine: machine, generator: generator, exported: exported, recordSeconds: recordSeconds,
                             records: records, events: kept, incident: incident)
    }

    // MARK: - Figures

    /// What each kind's contributors are ranked by: heat and network
    /// traffic aren't measured per process, so they go by CPU time.
    static func measure(_ kind: SpikeKind) -> SpikeContributor.Measure {
        switch kind {
        case .memory: .memory
        case .disk: .disk
        case .cpu, .thermal, .network: .cpu
        }
    }

    static func figure(_ kind: SpikeKind, _ sample: SpikeSample) -> Double {
        switch kind {
        case .cpu: sample.cpu
        case .memory: sample.memoryPressure
        case .thermal: SpikeTriggers.ordinal(sample.thermal)
        case .disk: sample.disk
        case .network: sample.network
        }
    }

    private static func ordinal(_ pressure: MemoryPressure) -> Double {
        switch pressure {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    private static func level(_ kind: SpikeKind, ordinal: Double) -> String? {
        switch kind {
        case .memory: ordinal >= 2 ? MemoryPressure.critical.rawValue : ordinal >= 1 ? MemoryPressure.warning.rawValue : nil
        case .thermal: ordinal >= 3 ? ThermalState.critical.rawValue : ordinal >= 2 ? ThermalState.serious.rawValue : nil
        case .cpu, .disk, .network: nil
        }
    }

    /// The processes in `moments`' top lists for `measure`, added up by
    /// process: CPU and disk by what they used over the window (their share
    /// of the whole), memory by its highest footprint.
    static func contributors(_ moments: [SpikeMoment], measure: SpikeContributor.Measure, logicalCores: Int,
                             kept: Int) -> [SpikeContributor] {
        struct Tally {
            let name: String
            var sum = 0.0
            var peak = 0.0
        }
        var tallies: [ProcessIdentity: Tally] = [:]
        var covered = 0.0
        var total = 0.0
        for moment in moments {
            let interval = moment.sample.interval
            covered += interval
            let list: [SpikeProcess]
            switch measure {
            case .cpu:
                total += moment.sample.cpu * Double(max(logicalCores, 1)) * 100 * interval
                list = moment.topCPU
            case .memory:
                list = moment.topMemory
            case .disk:
                total += moment.sample.disk * interval
                list = moment.topDisk
            }
            for process in list {
                var tally = tallies[process.identity] ?? Tally(name: process.name)
                tally.sum += process.value * interval
                tally.peak = max(tally.peak, process.value)
                tallies[process.identity] = tally
            }
        }
        guard covered > 0 else { return [] }
        let ranked = tallies.sorted { lhs, rhs in
            let left = measure == .memory ? lhs.value.peak : lhs.value.sum
            let right = measure == .memory ? rhs.value.peak : rhs.value.sum
            if left != right { return left > right }
            if lhs.value.name != rhs.value.name { return lhs.value.name < rhs.value.name }
            return lhs.key.pid < rhs.key.pid
        }
        return ranked.prefix(kept).map { identity, tally in
            let share: Double? = measure == .memory || total <= 0 ? nil : min(tally.sum / total, 1)
            return SpikeContributor(name: tally.name, identity: identity, measure: measure, average: tally.sum / covered,
                                    peak: tally.peak, share: share)
        }
    }

    /// One update's top list as the flight recorder's apps: by name, those
    /// sharing a name added up, highest first.
    static func apps(_ processes: [SpikeProcess]) -> [HistoryApp] {
        var totals: [String: Double] = [:]
        var order: [String] = []
        for process in processes {
            if totals[process.name] == nil { order.append(process.name) }
            totals[process.name, default: 0] += process.value
        }
        return order.map { HistoryApp(name: $0, value: totals[$0] ?? 0) }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }
}

extension SpikeTrigger {
    /// The trigger as a History event: the kind in a word ("CPU", "Memory")
    /// with what crossed as its detail, naming the pressure for a pressure
    /// kind ("Memory pressure reached warning").
    public var event: HistoryEvent {
        let detail = kind.shortLabel == kind.label ? summary : "\(kind.label) \(summary)"
        return HistoryEvent(time: time, kind: .spike, name: kind.shortLabel, detail: detail)
    }
}
