import Foundation

/// What made the spike recorder (`SpikeRecorder`) keep a capture.
public enum SpikeKind: String, Sendable, CaseIterable, Codable {
    /// The whole CPU stayed busy.
    case cpu
    /// The kernel's memory pressure reached warning or critical.
    case memory
    /// macOS's thermal pressure reached serious or critical.
    case thermal
    /// Disk reads and writes well above their usual rate, for a while.
    case disk
    /// Network traffic well above its usual rate, for a while.
    case network

    /// "CPU", "Memory pressure", "Disk".
    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory pressure"
        case .thermal: "Thermal pressure"
        case .disk: "Disk"
        case .network: "Network"
        }
    }
}

/// One condition crossing its threshold: what crossed, when, and the figure
/// that crossed (`SpikeTriggers`).
public struct SpikeTrigger: Sendable, Equatable {
    public let kind: SpikeKind
    /// The update that met the condition.
    public let time: Date
    /// When the condition began: the start of the busy stretch or burst, or
    /// of the update that raised the pressure.
    public let since: Date
    /// The figure that crossed, in the kind's unit. CPU: the share of the
    /// whole CPU, 0 to 1, averaged since `since`. Memory: the pressure, 0 to
    /// 1. Thermal: 2 for serious, 3 for critical. Disk and network: bytes
    /// per second, averaged since `since`.
    public let figure: Double
    /// What it had to reach, in the same unit: the CPU share; for disk and
    /// network the larger of the floor and the usual rate times the burst
    /// factor; 0 for memory and thermal, which go by `level`.
    public let threshold: Double
    /// The pressure level reached: memory's "warning" or "critical",
    /// thermal's "serious" or "critical"; nil for the others.
    public let level: String?
    /// Disk and network: the usual rate before the burst, bytes per second.
    public let baseline: Double?

    public init(kind: SpikeKind, time: Date, since: Date, figure: Double, threshold: Double, level: String? = nil,
                baseline: Double? = nil) {
        self.kind = kind
        self.time = time
        self.since = min(since, time)
        self.figure = figure
        self.threshold = threshold
        self.level = level
        self.baseline = baseline
    }

    /// What crossed, in a few words: "97% of the whole CPU for 10 s",
    /// "reached critical", "412 MB/s for 10 s, usually 2.1 MB/s".
    public var summary: String {
        let lasted = Format.timeSpan(time.timeIntervalSince(since).rounded())
        switch kind {
        case .cpu:
            return "\(Format.percent(figure)) of the whole CPU for \(lasted)"
        case .memory, .thermal:
            return "reached \(level ?? "a high level")"
        case .disk, .network:
            let usual = baseline.map { ", usually \(Format.bytesPerSecond($0))" } ?? ""
            return "\(Format.bytesPerSecond(figure)) for \(lasted)\(usual)"
        }
    }
}

/// A process that used much of the resource during an incident: the
/// spike recorder's per-update top lists added up by process (PID and start
/// time, so a reused PID is another process).
public struct SpikeContributor: Sendable, Equatable {
    /// What a contributor is ranked by.
    public enum Measure: String, Sendable, CaseIterable, Codable {
        /// CPU time; figures in percent of one core (100 = one core).
        case cpu
        /// Memory footprint; figures in bytes.
        case memory
        /// Disk reads and writes; figures in bytes per second.
        case disk
    }

    public let name: String
    public let identity: ProcessIdentity
    public let measure: Measure
    /// Its figure averaged over the incident, counting updates where it
    /// wasn't among the busiest as nothing.
    public let average: Double
    /// Its highest figure in a single update.
    public let peak: Double
    /// CPU: its share of all the CPU time used during the incident. Disk:
    /// its share of the bytes read and written. Nil for memory.
    public let share: Double?

    public init(name: String, identity: ProcessIdentity, measure: Measure, average: Double, peak: Double, share: Double?) {
        self.name = name
        self.identity = identity
        self.measure = measure
        self.average = average
        self.peak = peak
        self.share = share
    }

    /// Its figure in a few words: "48% of the CPU time" (or "85% of a core"
    /// without a share), "1.2 GB at most", "34 MB/s, 61% of the disk traffic".
    public var figureText: String {
        switch measure {
        case .cpu: share.map { "\(Format.percent($0)) of the CPU time" } ?? "\(Format.percent(average / 100)) of a core"
        case .memory: "\(Format.bytes(peak)) at most"
        case .disk: Format.bytesPerSecond(average) + (share.map { ", \(Format.percent($0)) of the disk traffic" } ?? "")
        }
    }
}

/// What a spike capture is about: the conditions that crossed during it
/// (the first started the capture), how long the first one lasted, and the
/// processes that used the most of its resource meanwhile.
public struct SpikeIncident: Sendable, Equatable {
    /// Never empty: the trigger that started the capture first, then any
    /// other kind that crossed within the capture, oldest first.
    public let triggers: [SpikeTrigger]
    /// When the first trigger's condition began, or the capture's start if
    /// it began before that.
    public let start: Date
    /// When it ended, or the capture's end if it carried on past it.
    public let end: Date
    /// Whether it carried on past the end of the capture.
    public let ongoing: Bool
    /// The first trigger's figure over the incident, in its unit: averaged
    /// over the updates, and the highest of them.
    public let average: Double
    public let peak: Double
    /// Memory and thermal: the highest level reached during the incident.
    public let level: String?
    /// The busiest first, at most `SpikeRecorder.contributorsKept`.
    public let contributors: [SpikeContributor]

    public init(triggers: [SpikeTrigger], start: Date, end: Date, ongoing: Bool, average: Double, peak: Double,
                level: String? = nil, contributors: [SpikeContributor] = []) {
        precondition(!triggers.isEmpty, "An incident has at least one trigger")
        self.triggers = triggers
        self.start = min(start, end)
        self.end = max(start, end)
        self.ongoing = ongoing
        self.average = average
        self.peak = peak
        self.level = level
        self.contributors = contributors
    }

    /// The trigger that started the capture.
    public var primary: SpikeTrigger { triggers[0] }

    public var kind: SpikeKind { primary.kind }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// "CPU at 97% for 25 s", "Memory pressure reached critical for 2 min+",
    /// "Disk at 412 MB/s for 30 s": "+" when it carried on past the capture.
    public var headline: String {
        let lasted = Format.roughDuration(max(duration, 1)) + (ongoing ? "+" : "")
        switch kind {
        case .cpu: return "CPU at \(Format.percent(average)) for \(lasted)"
        case .memory, .thermal: return "\(kind.label) reached \(level ?? primary.level ?? "a high level") for \(lasted)"
        case .disk, .network: return "\(kind.label) at \(Format.bytesPerSecond(average)) for \(lasted)"
        }
    }
}
