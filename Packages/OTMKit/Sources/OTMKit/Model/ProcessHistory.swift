import Foundation

/// One process as History keeps it (the flight recorder's schema 3): who it
/// was and when the recording saw it run. Keyed by `ProcessIdentity`, so a
/// PID macOS hands to a later process starts a lifetime of its own.
public struct ProcessLifetime: Sendable, Equatable, Identifiable, Codable {
    /// Its row in the recording.
    public let id: Int64
    public let identity: ProcessIdentity
    public var name: String
    public var path: String?
    public var user: String
    /// The identifier of the app bundle it runs from, when it runs from one.
    public var bundleID: String?
    /// launchd's label for its job, once the Startup page has seen it running.
    public var jobLabel: String?
    /// Another user's or a system process: CPU and resident memory only, no disk.
    public var isRestricted: Bool
    /// When the recording first saw it running.
    public var firstSeen: Date
    /// When the recording last saw it running: when it ended, if that was
    /// seen, or else the last record of the app's run that watched it.
    public var lastSeen: Date
    /// When it was seen to end. Nil while it runs, and for one that ended
    /// while nothing was recording.
    public var ended: Date?

    public init(id: Int64, identity: ProcessIdentity, name: String, path: String? = nil, user: String = "",
                bundleID: String? = nil, jobLabel: String? = nil, isRestricted: Bool = false,
                firstSeen: Date, lastSeen: Date, ended: Date? = nil) {
        self.id = id
        self.identity = identity
        self.name = name
        self.path = path
        self.user = user
        self.bundleID = bundleID
        self.jobLabel = jobLabel
        self.isRestricted = isRestricted
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.ended = ended
    }

    /// When it started: the kernel's start time, or when it was first seen.
    public var started: Date { identity.startTime.map { min($0, firstSeen) } ?? firstSeen }

    /// launchd's label, or else the bundle identifier.
    public var label: String? { jobLabel ?? bundleID }

    /// The stretch it ran within `range`: from its start to its end, or to
    /// `now` while `isRunning`, or else to when it was last seen. Nil when
    /// that misses `range`.
    public func span(within range: ClosedRange<Date>, isRunning: Bool, now: Date = .now) -> ClosedRange<Date>? {
        let end = isRunning ? now : (ended ?? lastSeen)
        let lower = max(started, range.lowerBound)
        let upper = min(end, range.upperBound)
        return lower <= upper ? lower...upper : nil
    }
}

/// A process's figures over one record.
public struct ProcessHistorySample: Sendable, Equatable, Codable {
    public let identity: ProcessIdentity
    /// Average CPU over the record, where 100 is one core.
    public var cpuPercent: Double
    /// Footprint at the record's end (resident memory for another user's
    /// process, which is all macOS gives), or at its last reading when it
    /// ended within the record.
    public var memory: UInt64
    /// Bytes per second read and written, averaged over the record. Nil
    /// where macOS doesn't give them (another user's or a system process).
    public var diskRead: Double?
    public var diskWrite: Double?

    public init(identity: ProcessIdentity, cpuPercent: Double, memory: UInt64, diskRead: Double?, diskWrite: Double?) {
        self.identity = identity
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }

    /// Read and written together, bytes per second; zero where unread.
    public var diskTotal: Double { (diskRead ?? 0) + (diskWrite ?? 0) }
}

/// Which processes a record keeps figures for. Every process gets a
/// lifetime, but figures cost a row each, so a record keeps only the ones
/// doing something:
///
/// - the `memoryTop` largest footprints, so the biggest apps' memory has
///   no holes;
/// - up to `diskTop` more that read and wrote at least `diskFloor` bytes a
///   second between them, busiest first;
/// - then those that averaged at least `cpuFloor` percent of one core,
///   busiest first;
/// - then any other disk users;
///
/// `cap` at most. A process left out was idle: under both floors and not
/// among the largest. History says "idle, not stored" there, never zero.
public enum ProcessHistoryKeep {
    /// Percent of one core, averaged over the record.
    public static let cpuFloor = 0.5
    /// Bytes a second read and written, averaged over the record.
    public static let diskFloor = 64.0 * 1024
    public static let memoryTop = 5
    public static let diskTop = 10
    public static let cap = 40

    /// The samples a record keeps, in the order the rule picks them.
    public static func select(_ samples: [ProcessHistorySample]) -> [ProcessHistorySample] {
        // Ties go to the lower PID, so the pick doesn't depend on the input's order.
        func ranked(_ list: [ProcessHistorySample], by figure: (ProcessHistorySample) -> Double) -> [ProcessHistorySample] {
            list.sorted { figure($0) == figure($1) ? $0.identity.pid < $1.identity.pid : figure($0) > figure($1) }
        }
        var kept: [ProcessHistorySample] = []
        var taken = Set<ProcessIdentity>()
        func take(_ list: [ProcessHistorySample], limit: Int = .max) {
            var added = 0
            for sample in list where added < limit && kept.count < cap && !taken.contains(sample.identity) {
                kept.append(sample)
                taken.insert(sample.identity)
                added += 1
            }
        }
        take(ranked(samples.filter { $0.memory > 0 }, by: { Double($0.memory) }), limit: memoryTop)
        let disk = ranked(samples.filter { $0.diskTotal >= diskFloor }, by: \.diskTotal)
        take(disk, limit: diskTop)
        take(ranked(samples.filter { $0.cpuPercent >= cpuFloor }, by: \.cpuPercent))
        take(disk)
        return kept
    }
}

/// What one record adds to the process history: the processes seen
/// starting and ending since the last, launchd labels learned, and the
/// figures the record keeps (`ProcessHistoryKeep`).
public struct ProcessHistoryBatch: Sendable, Equatable {
    /// A process seen for the first time.
    public struct Start: Sendable, Equatable {
        public let identity: ProcessIdentity
        public let name: String
        public let path: String?
        public let user: String
        public let isRestricted: Bool
        public let firstSeen: Date

        public init(identity: ProcessIdentity, name: String, path: String?, user: String, isRestricted: Bool, firstSeen: Date) {
            self.identity = identity
            self.name = name
            self.path = path
            self.user = user
            self.isRestricted = isRestricted
            self.firstSeen = firstSeen
        }

        public init(_ process: ProcessSample, at time: Date) {
            self.init(identity: process.identity, name: process.name, path: process.executablePath, user: process.userName,
                      isRestricted: process.isRestricted, firstSeen: time)
        }
    }

    /// A process gone from the list.
    public struct End: Sendable, Equatable {
        public let identity: ProcessIdentity
        public let time: Date
        /// False when it only stopped being watched (other users' and system
        /// processes, once they're no longer sampled): it may still run.
        public let isEnded: Bool

        public init(identity: ProcessIdentity, time: Date, isEnded: Bool) {
            self.identity = identity
            self.time = time
            self.isEnded = isEnded
        }
    }

    /// The record's time.
    public var time: Date
    public var started: [Start]
    /// launchd labels by process, for processes whose label wasn't known before.
    public var labels: [ProcessIdentity: String]
    public var samples: [ProcessHistorySample]
    public var ended: [End]

    public init(time: Date, started: [Start] = [], labels: [ProcessIdentity: String] = [:], samples: [ProcessHistorySample] = [],
                ended: [End] = []) {
        self.time = time
        self.started = started
        self.labels = labels
        self.samples = samples
        self.ended = ended
    }
}

/// A process's figures summed up over a stretch. Records where it ran but
/// wasn't kept (idle: `ProcessHistoryKeep`) count in `records` and add
/// nothing to the averages; stretches that weren't recorded count nowhere.
public struct ProcessHistorySummary: Sendable, Equatable, Codable {
    /// Records made while it ran, and how many of them kept its figures.
    public let records: Int
    public let stored: Int
    /// Seconds recorded while it ran.
    public let recordedSeconds: TimeInterval
    /// Percent of one core, over every record while it ran. Nil when none was.
    public let averageCPU: Double?
    /// The busiest record's average. Nil when none kept its figures.
    public let peakCPU: Double?
    public let peakMemory: UInt64?
    /// Bytes a second over every record while it ran. Nil when none was,
    /// or when its disk use can't be read.
    public let averageDiskRead: Double?
    public let averageDiskWrite: Double?

    public init(records: Int, stored: Int, recordedSeconds: TimeInterval, averageCPU: Double?, peakCPU: Double?,
                peakMemory: UInt64?, averageDiskRead: Double?, averageDiskWrite: Double?) {
        self.records = records
        self.stored = stored
        self.recordedSeconds = recordedSeconds
        self.averageCPU = averageCPU
        self.peakCPU = peakCPU
        self.peakMemory = peakMemory
        self.averageDiskRead = averageDiskRead
        self.averageDiskWrite = averageDiskWrite
    }

    public static let empty = ProcessHistorySummary(records: 0, stored: 0, recordedSeconds: 0, averageCPU: nil, peakCPU: nil,
                                                    peakMemory: nil, averageDiskRead: nil, averageDiskWrite: nil)

    /// Whether every record while it ran left it out as idle.
    public var isIdle: Bool { records > 0 && stored == 0 }
}

/// A lifetime that matches a search, with its figures over the range searched.
public struct ProcessHistoryMatch: Sendable, Equatable, Identifiable {
    public var id: Int64 { lifetime.id }
    public let lifetime: ProcessLifetime
    public let summary: ProcessHistorySummary

    public init(lifetime: ProcessLifetime, summary: ProcessHistorySummary) {
        self.lifetime = lifetime
        self.summary = summary
    }
}

/// One point of a process's History charts: the records in one bucket
/// while it ran. What each figure says depends on `state`: a bucket with no
/// records isn't a point at all (a gap in the recording, or the process not
/// running), and one whose records all left it out is idle, not stored,
/// with no figures, never zeros.
public struct ProcessHistoryPoint: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Every record kept its figures.
        case stored
        /// Some records left it out as idle; they count as nothing in the averages.
        case partlyIdle
        /// Every record left it out as idle.
        case idle
    }

    public var id: Date { time }
    /// The bucket's last record, as for `HistoryPoint`.
    public let time: Date
    /// Records in the bucket while it ran, and how many kept its figures.
    public let records: Int
    public let stored: Int
    /// Percent of one core, averaged over `records`. Nil when idle.
    public let cpu: Double?
    /// The busiest record's average. Nil when idle.
    public let cpuPeak: Double?
    /// The largest footprint the bucket kept. Nil when idle.
    public let memory: Double?
    /// Bytes a second averaged over `records`. Nil when idle or unread.
    public let diskRead: Double?
    public let diskWrite: Double?
    /// Increases after each gap in the recording, as `HistoryPoint.segment` does.
    public var segment: Int

    public init(time: Date, records: Int, stored: Int, cpu: Double?, cpuPeak: Double?, memory: Double?,
                diskRead: Double?, diskWrite: Double?, segment: Int = 0) {
        self.time = time
        self.records = records
        self.stored = stored
        self.cpu = cpu
        self.cpuPeak = cpuPeak
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.segment = segment
    }

    public var state: State {
        stored == 0 ? .idle : stored < records ? .partlyIdle : .stored
    }

    /// The point closest to `time` among `points` (oldest first), if it's
    /// within `bucket` seconds: the bucket a pinned moment falls in.
    public static func at(_ time: Date, in points: [ProcessHistoryPoint], bucket: TimeInterval) -> ProcessHistoryPoint? {
        let nearest = points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
        guard let nearest, time > nearest.time.addingTimeInterval(-bucket), time <= nearest.time.addingTimeInterval(bucket / 2) else {
            return nil
        }
        return nearest
    }

    /// The stretches where `points` are idle, each bucket reaching back
    /// `bucket` seconds from its point's time, joined where they touch
    /// within a segment: what the charts mark "idle, not stored".
    public static func idleStretches(_ points: [ProcessHistoryPoint], bucket: TimeInterval) -> [ClosedRange<Date>] {
        var stretches: [ClosedRange<Date>] = []
        var previous: ProcessHistoryPoint?
        for point in points {
            defer { previous = point }
            guard point.state == .idle else { continue }
            let start = point.time.addingTimeInterval(-bucket)
            if let last = stretches.last, let previous, previous.state == .idle, previous.segment == point.segment {
                stretches[stretches.count - 1] = last.lowerBound...point.time
            } else {
                stretches.append(start...point.time)
            }
        }
        return stretches
    }
}

/// How History's process search reads a query.
public enum ProcessHistorySearch {
    /// The query without surrounding spaces, or nil when nothing's left.
    public static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A SQLite `LIKE` pattern (with `ESCAPE '\'`) that finds `query`
    /// anywhere, its `%`, `_` and `\` taken literally. `LIKE` ignores the
    /// case of ASCII letters.
    public static func likePattern(_ query: String) -> String {
        var escaped = ""
        for character in query {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    /// A query that's a whole number also finds the process with that PID.
    public static func pid(_ query: String) -> Int32? {
        guard query.allSatisfy(\.isASCII) else { return nil }
        return Int32(query)
    }
}
