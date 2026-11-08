import Foundation

/// Follows the processes from tick to tick for History's process history:
/// notes each process the tick it's first seen and the tick it's gone, and
/// at each record's end takes native CPU and disk from cumulative counters.
/// Restricted CPU is integrated from the sampler's held rates between ps
/// reads, so a repeated counter cannot turn a busy record into zero.
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
/// counted at all. A new process seen at a record's end waits one record:
/// still running then, it keeps its lifetime with the original first-seen
/// time; ended without kept figures, it is only counted. Kept figures
/// always get a lifetime at once.
public struct ProcessHistoryTracker: Sendable {
    /// A process's cumulative counters.
    struct Counters: Sendable, Equatable {
        var cpuSeconds: Double
        var diskRead: Double
        var diskWrite: Double
        var memory: ProcessMemoryState?

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
        var track: ProcessMemoryState?
        let lastReading: Date
    }

    public let span: TimeInterval
    /// The app's own PID: processes it starts aren't counted as short runs.
    public let ownPID: Int32
    /// Whether other users' and system processes are sampled. While they
    /// aren't, one gone from the list hasn't necessarily ended.
    public var watchesRestricted = true
    /// When the record being made began: the last one's end.
    private var recordStart: Date?
    /// The app's own children seen starting since the last record, or deferred.
    private var children: Set<ProcessIdentity> = []
    /// Each process's counters at the start of the stretch, or at its own
    /// start within it.
    private var baselines: [ProcessIdentity: Counters] = [:]
    /// Restricted counters can be five seconds old. Integrate the held CPU
    /// rate so a record boundary between reads never invents an idle stretch.
    private var restrictedCPU: [ProcessIdentity: Double] = [:]
    private var needsBaselines = true
    private var finished: [Finished] = []
    private var memoryEnds: [ProcessMemoryUpdate] = []
    private var memoryPending: [ProcessMemoryUpdate] = []
    private var covered = 0.0
    private var last: Date?
    private var started: [ProcessHistoryBatch.Start] = []
    /// Idle starts held for one record, with their original first sightings.
    private var deferred: [ProcessHistoryBatch.Start] = []
    private var deferredSince: Date?
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
                                                 isEnded: watchesRestricted || !process.isRestricted, lastSeen: last))
        }

        if afterGap {
            closeMemoryStretch()
            resetStretch()
        }
        guard interval > 0, interval <= span else { return }
        let previousTime = last
        last = time
        for process in samples where process.isRestricted {
            let seconds = process.startTime.map { min(interval, max(time.timeIntervalSince($0), 0)) } ?? interval
            restrictedCPU[process.identity, default: 0] += process.cpuPercent / 100 * seconds
        }
        if needsBaselines {
            baselines = Dictionary(samples.map { ($0.identity, baseline(before: $0, interval: interval, at: time)) },
                                   uniquingKeysWith: { first, _ in first })
            needsBaselines = false
        } else {
            for process in appeared { baselines[process.identity] = baseline(before: process, interval: interval, at: time) }
        }
        observeMemory(samples, at: time)
        for process in disappeared {
            defer { restrictedCPU.removeValue(forKey: process.identity) }
            guard let base = baselines.removeValue(forKey: process.identity) else { continue }
            finished.append(Finished(identity: process.identity, used: Self.used(counters(process), since: base),
                                     memory: process.memory, isRestricted: process.isRestricted,
                                     track: base.memory, lastReading: previousTime ?? time))
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
                figures.append(figure(process.identity, used: Self.used(counters(process), since: base), memory: process.memory,
                                      isRestricted: process.isRestricted))
            }
            for process in finished {
                figures.append(figure(process.identity, used: process.used, memory: process.memory, isRestricted: process.isRestricted))
            }
        }
        let kept = ProcessHistoryKeep.select(figures)
        let short = shortRuns(kept: kept, since: recordStart ?? time.addingTimeInterval(-span))
        let keptIdentities = Set(kept.lazy.map(\.identity))
        let running = Set(samples.lazy.map(\.identity))
        let waiting = Set(started.lazy.filter { running.contains($0.identity) && !keptIdentities.contains($0.identity) }.map(\.identity))
        let starts = (deferred + started).filter { !waiting.contains($0.identity) && !short.identities.contains($0.identity) }
        // A label can arrive while its start is deferred, then disappear from
        // launchd's list before the next record. Hand it on with the lifetime.
        var learned = Dictionary(starts.compactMap { start in labelsNoted[start.identity].map { (start.identity, $0) } },
                                 uniquingKeysWith: { _, latest in latest })
        for (identity, label) in labels where labelsNoted[identity] != label && !short.identities.contains(identity) {
            if !waiting.contains(identity) { learned[identity] = label }
            labelsNoted[identity] = label
        }
        let memory = memoryUpdates(samples: samples, waiting: waiting, short: short.identities, at: time)
        let batch = ProcessHistoryBatch(
            time: time, started: starts,
            labels: learned, samples: kept,
            ended: short.identities.isEmpty ? ended : ended.filter { !short.identities.contains($0.identity) }, shortRuns: short.runs, memory: memory
        )
        deferred = started.filter { waiting.contains($0.identity) }
        deferredSince = time
        started = []
        for end in ended { labelsNoted.removeValue(forKey: end.identity) }
        ended = []
        children.formIntersection(waiting)
        recordStart = time
        finished = []
        covered = 0
        if !needsBaselines {
            var next: [ProcessIdentity: Counters] = [:]
            next.reserveCapacity(samples.count)
            for process in samples {
                var counter = counters(process)
                counter.memory = baselines[process.identity]?.memory
                next[process.identity] = counter
            }
            baselines = next
        }
        return batch
    }

    /// The processes that started at or after `since` (the record's start,
    /// by the kernel's start time), or were deferred at its start, and ended,
    /// none of them in `kept`, and how many of each kind, the app's own
    /// children left out of the counts.
    private func shortRuns(kept: [ProcessHistorySample],
                           since: Date) -> (identities: Set<ProcessIdentity>, runs: [ProcessHistoryBatch.ShortRuns]) {
        guard !started.isEmpty || !deferred.isEmpty, !ended.isEmpty else { return ([], []) }
        let gone = Set(ended.lazy.filter(\.isEnded).map(\.identity))
        let keptIdentities = Set(kept.lazy.map(\.identity))
        let deferredIdentities = Set(deferred.lazy.map(\.identity))
        var identities = Set<ProcessIdentity>()
        var counts: [ShortRunKind: Int] = [:]
        for start in deferred + started where gone.contains(start.identity) && !keptIdentities.contains(start.identity) {
            if deferredIdentities.contains(start.identity) {
                // A gap changed the record's start: its end was not watched throughout.
                guard deferredSince == since else { continue }
            } else {
                guard let began = start.identity.startTime, began >= since else { continue }
            }
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

    private func counters(_ process: ProcessSample) -> Counters {
        var result = Counters(process)
        if process.isRestricted { result.cpuSeconds = restrictedCPU[process.identity] ?? 0 }
        return result
    }

    private func baseline(before process: ProcessSample, interval: TimeInterval, at time: Date) -> Counters {
        var result = process.isRestricted ? counters(process) : Counters(before: process, interval: interval, at: time)
        result.memory = ProcessMemoryState(process, at: time)
        guard process.isRestricted else { return result }
        let seconds = process.startTime.map { min(interval, max(time.timeIntervalSince($0), 0)) } ?? interval
        result.cpuSeconds -= process.cpuPercent / 100 * seconds
        return result
    }

    /// Reuses sampler figures; thresholds share a buffer and peaks remain
    /// in value state until the record writes them once. No new reads.
    private mutating func observeMemory(_ samples: [ProcessSample], at time: Date) {
        for process in samples {
            guard var state = baselines[process.identity]?.memory else { continue }
            state.record(process, at: time, reportPeak: false, into: &memoryPending)
            baselines[process.identity]?.memory = state
        }
    }

    /// One pass over existing entries, with value state and one shared output buffer.
    private mutating func memoryUpdates(samples: [ProcessSample], waiting: Set<ProcessIdentity>,
                                        short: Set<ProcessIdentity>, at time: Date) -> [ProcessMemoryUpdate] {
        var updates = memoryEnds.filter { !short.contains($0.identity) && !waiting.contains($0.identity) }
        updates.append(contentsOf: memoryPending.filter { !short.contains($0.identity) && !waiting.contains($0.identity) })
        memoryPending = memoryPending.filter { waiting.contains($0.identity) && !short.contains($0.identity) }
        memoryEnds.removeAll(keepingCapacity: true)
        for process in samples where !waiting.contains(process.identity) {
            guard var state = baselines[process.identity]?.memory else { continue }
            state.record(process, at: time, into: &updates)
            baselines[process.identity]?.memory = state
        }
        for process in finished where !short.contains(process.identity) {
            guard var state = process.track else { continue }
            let step = ProcessMemoryStep(time: process.lastReading, footprint: process.memory,
                                         measure: process.isRestricted ? .resident : .footprint)
            state.record(step, identity: process.identity, ending: true, into: &updates)
        }
        return updates
    }

    private mutating func closeMemoryStretch() {
        for (identity, counter) in baselines {
            guard var state = counter.memory, state.stored != nil else { continue }
            state.record(state.latest, identity: identity, ending: true, into: &memoryEnds)
        }
    }

    private mutating func resetStretch() {
        restrictedCPU = [:]
        baselines = [:]
        needsBaselines = true
        finished = []
        covered = 0
        last = nil
    }
}
