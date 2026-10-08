import Foundation

/// Follows the processes from tick to tick for History's process history:
/// notes each process the tick it's first seen and the tick it's gone, and
/// at each record's end takes every process's average CPU and disk over the
/// record from the cumulative counters the sampler already read, so between
/// records a tick costs work only for the processes that started or ended.
///
/// Stretches follow `HistoryAccumulator`'s: a tick longer than a record, or
/// a gap between ticks, starts afresh, so a record's figures never cover
/// time nobody watched.
///
/// A process that started and ended within one record, its end seen, with
/// no figures kept (a shell's `sleep`, a build's compiler runs), gets no
/// lifetime of its own: the record counts it with others of its name,
/// executable and user (`ProcessHistoryBatch.ShortRuns`). One the app
/// itself started (its own `ps`, `nettop` or `launchctl` reads) isn't
/// counted at all. Anything seen at a record's end, or kept with figures,
/// keeps its lifetime.
public struct ProcessHistoryTracker: Sendable {
    /// A process's cumulative counters.
    struct Counters: Sendable, Equatable {
        var cpuSeconds: Double
        var diskRead: Double
        var diskWrite: Double

        static let zero = Counters(cpuSeconds: 0, diskRead: 0, diskWrite: 0)

        init(cpuSeconds: Double, diskRead: Double, diskWrite: Double) {
            self.cpuSeconds = cpuSeconds
            self.diskRead = diskRead
            self.diskWrite = diskWrite
        }

        /// As the process stands now.
        init(_ process: ProcessSample) {
            self.init(cpuSeconds: process.cpuTime, diskRead: Double(process.diskReadTotal), diskWrite: Double(process.diskWriteTotal))
        }

        /// As it stood a tick of `interval` seconds before `time`: nothing
        /// for a process that started since, otherwise now less the tick's
        /// rates, which the sampler took from these same counters.
        init(before process: ProcessSample, interval: TimeInterval, at time: Date) {
            if let start = process.startTime, start > time.addingTimeInterval(-interval) {
                self = .zero
                return
            }
            self.init(cpuSeconds: max(process.cpuTime - process.cpuPercent / 100 * interval, 0),
                      diskRead: max(Double(process.diskReadTotal) - process.diskReadRate * interval, 0),
                      diskWrite: max(Double(process.diskWriteTotal) - process.diskWriteRate * interval, 0))
        }
    }

    /// What a process that ended within the stretch used of it.
    private struct Finished: Sendable {
        let identity: ProcessIdentity
        let used: Counters
        let memory: UInt64
        let isRestricted: Bool
    }

    public let span: TimeInterval
    /// The app's own PID: processes it starts aren't counted as short runs.
    public let ownPID: Int32
    /// Whether other users' and system processes are sampled. While they
    /// aren't, one gone from the list hasn't necessarily ended.
    public var watchesRestricted = true
    /// When the record being made began: the last one's end.
    private var recordStart: Date?
    /// The app's own children seen starting since the last record.
    private var children: Set<ProcessIdentity> = []
    /// Each process's counters at the start of the stretch, or at its own
    /// start within it.
    private var baselines: [ProcessIdentity: Counters] = [:]
    private var needsBaselines = true
    private var finished: [Finished] = []
    private var covered = 0.0
    private var last: Date?
    private var started: [ProcessHistoryBatch.Start] = []
    private var ended: [ProcessHistoryBatch.End] = []
    /// The launchd labels handed on already, by process.
    private var labelsNoted: [ProcessIdentity: String] = [:]

    public init(span: TimeInterval = FlightRecorder.span, ownPID: Int32 = getpid()) {
        self.span = span
        self.ownPID = ownPID
    }

    /// Notes one tick covering `interval` seconds up to `time`. `samples` is
    /// every process now; `appeared`, those that weren't in the previous
    /// tick; `disappeared`, the previous tick's samples of those gone since.
    /// One gone after a gap (a pause, sleep) ended when it was last seen,
    /// not across the gap.
    public mutating func add(_ samples: [ProcessSample], appeared: [ProcessSample], disappeared: [ProcessSample],
                             interval: TimeInterval, at time: Date) {
        let afterGap = interval > span || last.map { time.timeIntervalSince($0) > interval + span } ?? false
        let endTime = afterGap ? last ?? time : time
        if afterGap {
            // One that started before or during the gap may have run all through it: only later ones are short runs.
            recordStart = time
        } else if recordStart == nil {
            recordStart = time.addingTimeInterval(-min(max(interval, 0), span))
        }
        for process in appeared {
            started.append(ProcessHistoryBatch.Start(process, at: time))
            if process.parentPID == ownPID { children.insert(process.identity) }
        }
        for process in disappeared {
            ended.append(ProcessHistoryBatch.End(identity: process.identity, time: endTime,
                                                 isEnded: watchesRestricted || !process.isRestricted))
            labelsNoted.removeValue(forKey: process.identity)
        }

        if afterGap {
            resetStretch()
        }
        guard interval > 0, interval <= span else { return }
        last = time
        if needsBaselines {
            baselines = Dictionary(samples.map { ($0.identity, Counters(before: $0, interval: interval, at: time)) },
                                   uniquingKeysWith: { first, _ in first })
            needsBaselines = false
        } else {
            for process in appeared { baselines[process.identity] = Counters(before: process, interval: interval, at: time) }
        }
        for process in disappeared {
            guard let base = baselines.removeValue(forKey: process.identity) else { continue }
            finished.append(Finished(identity: process.identity, used: Self.used(Counters(process), since: base),
                                     memory: process.memory, isRestricted: process.isRestricted))
        }
        covered += interval
    }

    /// Ends the record at `time`, once `HistoryAccumulator` has made it:
    /// the figures it keeps (`ProcessHistoryKeep`) from `samples`, the
    /// processes now, and those that ended within it, with the starts, ends
    /// and new launchd `labels` since the last record, and the short runs
    /// counted in their place.
    public mutating func close(at time: Date, samples: [ProcessSample], labels: [ProcessIdentity: String] = [:]) -> ProcessHistoryBatch {
        var figures: [ProcessHistorySample] = []
        if covered > 0, !needsBaselines {
            figures.reserveCapacity(samples.count + finished.count)
            for process in samples {
                guard let base = baselines[process.identity] else { continue }
                figures.append(figure(process.identity, used: Self.used(Counters(process), since: base), memory: process.memory,
                                      isRestricted: process.isRestricted))
            }
            for process in finished {
                figures.append(figure(process.identity, used: process.used, memory: process.memory, isRestricted: process.isRestricted))
            }
        }
        let kept = ProcessHistoryKeep.select(figures)
        let short = shortRuns(kept: kept, since: recordStart ?? time.addingTimeInterval(-span))
        var learned: [ProcessIdentity: String] = [:]
        for (identity, label) in labels where labelsNoted[identity] != label && !short.identities.contains(identity) {
            learned[identity] = label
            labelsNoted[identity] = label
        }
        let batch = ProcessHistoryBatch(
            time: time, started: short.identities.isEmpty ? started : started.filter { !short.identities.contains($0.identity) },
            labels: learned, samples: kept,
            ended: short.identities.isEmpty ? ended : ended.filter { !short.identities.contains($0.identity) }, shortRuns: short.runs
        )
        started = []
        ended = []
        children = []
        recordStart = time
        finished = []
        covered = 0
        if !needsBaselines {
            var next: [ProcessIdentity: Counters] = [:]
            next.reserveCapacity(samples.count)
            for process in samples { next[process.identity] = Counters(process) }
            baselines = next
        }
        return batch
    }

    /// The processes that started at or after `since` (the record's start,
    /// by the kernel's start time) and were seen to end within the record,
    /// none of them in `kept`, and how many of each kind, the app's own
    /// children left out of the counts.
    private func shortRuns(kept: [ProcessHistorySample],
                           since: Date) -> (identities: Set<ProcessIdentity>, runs: [ProcessHistoryBatch.ShortRuns]) {
        guard !started.isEmpty, !ended.isEmpty else { return ([], []) }
        let gone = Set(ended.lazy.filter(\.isEnded).map(\.identity))
        let keptIdentities = Set(kept.lazy.map(\.identity))
        var identities = Set<ProcessIdentity>()
        var counts: [ShortRunKind: Int] = [:]
        for start in started where gone.contains(start.identity) && !keptIdentities.contains(start.identity) {
            guard let began = start.identity.startTime, began >= since else { continue }
            identities.insert(start.identity)
            if !children.contains(start.identity) {
                counts[ShortRunKind(name: start.name, path: start.path, user: start.user), default: 0] += 1
            }
        }
        let runs = counts.map { ProcessHistoryBatch.ShortRuns(name: $0.key.name, path: $0.key.path, user: $0.key.user, count: $0.value) }
        return (identities, runs.sorted { ($0.name, $0.path ?? "", $0.user) < ($1.name, $1.path ?? "", $1.user) })
    }

    private struct ShortRunKind: Hashable {
        let name: String
        let path: String?
        let user: String
    }

    private func figure(_ identity: ProcessIdentity, used: Counters, memory: UInt64, isRestricted: Bool) -> ProcessHistorySample {
        ProcessHistorySample(identity: identity, cpuPercent: used.cpuSeconds / covered * 100, memory: memory,
                             diskRead: isRestricted ? nil : used.diskRead / covered,
                             diskWrite: isRestricted ? nil : used.diskWrite / covered)
    }

    private static func used(_ now: Counters, since base: Counters) -> Counters {
        Counters(cpuSeconds: max(now.cpuSeconds - base.cpuSeconds, 0), diskRead: max(now.diskRead - base.diskRead, 0),
                 diskWrite: max(now.diskWrite - base.diskWrite, 0))
    }

    private mutating func resetStretch() {
        baselines = [:]
        needsBaselines = true
        finished = []
        covered = 0
        last = nil
    }
}
