import Foundation
import OTMKit

/// `otm history processes QUERY`: the processes the app's History recorded
/// whose name, executable path, bundle identifier or launchd label holds
/// QUERY (or whose PID it is), latest first, with when each ran and its
/// figures, and the short runs counted by kind rather than kept one by one.
/// Reads the app's recording without writing to it.
func historyCommand(_ options: Options) async {
    guard options.positional.first == "processes" else {
        fail("usage: otm history processes QUERY [--range 1h|6h|24h|7d] [-n COUNT] [--json]")
    }
    let query = options.positional.dropFirst().joined(separator: " ")
    guard ProcessHistorySearch.normalized(query) != nil else { fail("history processes needs a name, path, label or PID to search for") }
    guard let range = HistoryRangeOption(options.range ?? "24h") else { fail("--range takes 1h, 6h, 24h or 7d") }
    let url = FlightRecorder.defaultURL
    let recorder: FlightRecorder
    do {
        recorder = try FlightRecorder(reading: url)
    } catch {
        fail("no history at \(url.path): OpenTaskManager writes it while it runs")
    }
    let end = Date.now
    let start = end.addingTimeInterval(-range.seconds)
    let matches: [ProcessHistoryMatch]
    let shortRuns: [ProcessHistoryShortRuns]
    do {
        guard try await recorder.keepsProcessHistory() else {
            fail("the history at \(url.path) has no process history yet: run this version of OpenTaskManager to start keeping it")
        }
        matches = try await recorder.processLifetimes(matching: query, from: start, to: end, limit: max(options.count, 1))
        shortRuns = try await recorder.processShortRuns(matching: query, from: start, to: end, limit: max(options.count, 1))
    } catch {
        fail("couldn't read \(url.path): \(error)")
    }
    // Still running: the process with its PID now is the same one, started at the same time.
    let running = Set(matches.filter { match in
        match.lifetime.ended == nil && ProcessDetailReader.identity(of: match.lifetime.identity.pid) == match.lifetime.identity
    }.map(\.id))
    let found = ProcessHistoryFound(matches: matches, shortRuns: shortRuns, running: running)
    if options.json {
        printJSON(ProcessHistoryReport(query: query, from: start, to: end, found: found))
    } else {
        print(processHistoryList(found, query: query, range: range, end: end))
    }
}

/// `--range`: how far back to search.
struct HistoryRangeOption {
    let seconds: TimeInterval
    let phrase: String

    init?(_ text: String) {
        switch text.lowercased() {
        case "1h": (seconds, phrase) = (3_600, "the last hour")
        case "6h": (seconds, phrase) = (21_600, "the last 6 hours")
        case "24h", "1d": (seconds, phrase) = (86_400, "the last 24 hours")
        case "7d", "1w": (seconds, phrase) = (604_800, "the last 7 days")
        default: return nil
        }
    }
}

/// What a search found: lifetimes, which of them still run, and short runs.
struct ProcessHistoryFound {
    let matches: [ProcessHistoryMatch]
    let shortRuns: [ProcessHistoryShortRuns]
    /// Lifetimes still running, by row.
    let running: Set<Int64>
}

/// `otm history processes --json`. CPU is percent of one core; a figure
/// left out wasn't kept (the process was idle in every record, or its disk
/// use can't be read), never zero. `shortRuns` are processes that started
/// and ended within one record with no figures kept, counted by name,
/// executable and user over records that follow on: no PIDs, no figures.
struct ProcessHistoryReport: Encodable {
    struct Entry: Encodable {
        let name: String
        let pid: Int32
        let startTime: Date?
        let path: String?
        let user: String
        let bundleID: String?
        let launchdLabel: String?
        let restricted: Bool
        let firstSeen: Date
        let lastSeen: Date
        let ended: Date?
        let running: Bool
        /// Records made while it ran within the range, and how many kept its figures.
        let records: Int
        let storedRecords: Int
        let recordedSeconds: Double
        let averageCPU: Double?
        let peakCPU: Double?
        let peakMemory: UInt64?
        let averageDiskRead: Double?
        let averageDiskWrite: Double?
    }

    let query: String
    let from: Date
    let to: Date
    let cpuUnit = "percent of one core"
    let processes: [Entry]
    let shortRuns: [ProcessHistoryShortRuns]

    init(query: String, from: Date, to: Date, found: ProcessHistoryFound) {
        self.query = query
        self.from = from
        self.to = to
        shortRuns = found.shortRuns
        processes = found.matches.map { match in
            let lifetime = match.lifetime
            let summary = match.summary
            return Entry(
                name: lifetime.name, pid: lifetime.identity.pid, startTime: lifetime.identity.startTime, path: lifetime.path,
                user: lifetime.user, bundleID: lifetime.bundleID, launchdLabel: lifetime.jobLabel, restricted: lifetime.isRestricted,
                firstSeen: lifetime.firstSeen, lastSeen: lifetime.lastSeen, ended: lifetime.ended,
                running: found.running.contains(match.id),
                records: summary.records, storedRecords: summary.stored, recordedSeconds: summary.recordedSeconds,
                averageCPU: summary.averageCPU, peakCPU: summary.peakCPU, peakMemory: summary.peakMemory,
                averageDiskRead: summary.averageDiskRead, averageDiskWrite: summary.averageDiskWrite
            )
        }
    }
}

func processHistoryList(_ found: ProcessHistoryFound, query: String, range: HistoryRangeOption, end: Date) -> String {
    let runs = found.shortRuns.reduce(0) { $0 + $1.count }
    var heading: [String] = []
    if !found.matches.isEmpty { heading.append("\(found.matches.count) \(found.matches.count == 1 ? "process" : "processes")") }
    if runs > 0 { heading.append("\(runs) short \(runs == 1 ? "run" : "runs")") }
    guard !heading.isEmpty else { return "Nothing matching \"\(query)\" ran while History was recording in \(range.phrase)." }
    let list = HistoryProcessList(range: range, end: end)
    // Latest first, lifetimes and short runs together.
    var blocks: [(time: Date, lines: [String])] = found.matches.map { match in
        let isRunning = found.running.contains(match.id)
        return (isRunning ? end : match.lifetime.ended ?? match.lifetime.lastSeen, list.lines(match, isRunning: isRunning))
    }
    blocks += found.shortRuns.map { ($0.to, list.lines($0)) }
    blocks.sort { $0.time > $1.time }
    var lines = [heading.joined(separator: " and ") + " matching \"\(query)\" in \(range.phrase), latest first (CPU: 100% is one core)"]
    for block in blocks { lines += [""] + block.lines }
    return lines.joined(separator: "\n")
}

/// Each result's lines in `otm history processes`.
private struct HistoryProcessList {
    let range: HistoryRangeOption
    let end: Date
    private let time = Date.FormatStyle(date: .omitted, time: .standard)
    private let dated = Date.FormatStyle(date: .abbreviated, time: .standard)

    init(range: HistoryRangeOption, end: Date) {
        self.range = range
        self.end = end
    }

    func clock(_ date: Date) -> String { date.formatted(Calendar.current.isDateInToday(date) ? time : dated) }

    func lines(_ match: ProcessHistoryMatch, isRunning: Bool) -> [String] {
        let lifetime = match.lifetime
        let summary = match.summary
        let state = isRunning ? "running" : lifetime.ended.map { "ended \(clock($0))" } ?? "last seen \(clock(lifetime.lastSeen))"
        var lines = ["\(lifetime.name)  PID \(lifetime.identity.pid)  \(state)"]
        let rangeStart = end.addingTimeInterval(-range.seconds)
        let from = max(lifetime.started, rangeStart)
        let to = isRunning ? end : (lifetime.ended ?? lifetime.lastSeen)
        let duration = Format.roughDuration(max(to.timeIntervalSince(from), 0))
        var figures = [
            lifetime.started >= rangeStart ? "\(clock(from)) – \(clock(to)) (\(duration))"
                : isRunning ? "started \(clock(lifetime.started)), running throughout the range"
                : "started \(clock(lifetime.started)), ran to \(clock(to)) (\(duration) in the range)",
        ]
        if summary.records == 0 {
            figures.append("not recorded while it ran")
        } else if let average = summary.averageCPU, let peak = summary.peakCPU {
            figures.append("CPU avg \(Format.fixed(average, 1))%, peak \(Format.fixed(peak, 1))%")
            if let memory = summary.peakMemory { figures.append("memory peak \(Format.bytes(memory))") }
            if let read = summary.averageDiskRead, let write = summary.averageDiskWrite {
                figures.append("disk avg read \(Format.bytesPerSecond(read)), write \(Format.bytesPerSecond(write))")
            }
            if summary.stored < summary.records {
                figures.append("idle, not stored, in \(summary.records - summary.stored) of \(summary.records) records")
            }
        } else {
            figures.append("idle throughout, not stored")
        }
        lines.append("  " + figures.joined(separator: " · "))
        let about = [lifetime.path, lifetime.label, lifetime.user.isEmpty ? nil : "user \(lifetime.user)"].compactMap { $0 }
        if !about.isEmpty { lines.append("  " + about.joined(separator: " · ")) }
        return lines
    }

    func lines(_ runs: ProcessHistoryShortRuns) -> [String] {
        var lines = ["\(runs.name)  \(runs.count) short \(runs.count == 1 ? "run" : "runs")",
                     "  between \(clock(runs.from)) and \(clock(runs.to)), each started and ended within a record "
                         + "(\(Format.roughDuration(FlightRecorder.span))) with no figures kept"]
        let about = [runs.path, runs.user.isEmpty ? nil : "user \(runs.user)"].compactMap { $0 }
        if !about.isEmpty { lines.append("  " + about.joined(separator: " · ")) }
        return lines
    }
}
