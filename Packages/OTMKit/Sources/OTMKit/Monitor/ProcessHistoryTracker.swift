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

    public init(span: TimeInterval = FlightRecorder.span) {
        self.span = span
    }

    /// Notes one tick covering `interval` seconds up to `time`. `samples` is
    /// every process now; `appeared`, those that weren't in the previous
    /// tick; `disappeared`, the previous tick's samples of those gone since.
    /// While `watchesRestricted` is false, other users' and system processes
    /// aren't sampled, so their going isn't their end.
    public mutating func add(_ samples: [ProcessSample], appeared: [ProcessSample], disappeared: [ProcessSample],
                             watchesRestricted: Bool, interval: TimeInterval, at time: Date) {
        for process in appeared { started.append(ProcessHistoryBatch.Start(process, at: time)) }
        for process in disappeared {
            ended.append(ProcessHistoryBatch.End(identity: process.identity, time: time,
                                                 isEnded: watchesRestricted || !process.isRestricted))
            labelsNoted.removeValue(forKey: process.identity)
        }

        if let last, time.timeIntervalSince(last) > interval + span || interval > span {
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
    /// and new launchd `labels` since the last record.
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
        var learned: [ProcessIdentity: String] = [:]
        for (identity, label) in labels where labelsNoted[identity] != label {
            learned[identity] = label
            labelsNoted[identity] = label
        }
        let batch = ProcessHistoryBatch(time: time, started: started, labels: learned, samples: ProcessHistoryKeep.select(figures),
                                        ended: ended)
        started = []
        ended = []
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
