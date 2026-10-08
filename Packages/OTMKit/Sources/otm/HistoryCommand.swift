import Foundation
import OTMKit

/// `otm history processes QUERY`: the processes the app's History recorded
/// whose name, executable path, bundle identifier or launchd label holds
/// QUERY (or whose PID it is), latest first, with when each ran and its
/// figures. Reads the app's recording without writing to it.
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
    do {
        guard try await recorder.keepsProcessHistory() else {
            fail("the history at \(url.path) has no process history yet: run this version of OpenTaskManager to start keeping it")
        }
        matches = try await recorder.processLifetimes(matching: query, from: start, to: end, limit: max(options.count, 1))
    } catch {
        fail("couldn't read \(url.path): \(error)")
    }
    // Still running: the process with its PID now is the same one, started at the same time.
    let running = Set(matches.filter { match in
        match.lifetime.ended == nil && ProcessDetailReader.identity(of: match.lifetime.identity.pid) == match.lifetime.identity
    }.map(\.id))
    if options.json {
        printJSON(ProcessHistoryReport(query: query, from: start, to: end, matches: matches, running: running))
    } else {
        print(processHistoryList(matches, query: query, range: range, running: running, end: end))
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

/// `otm history processes --json`. CPU is percent of one core; a figure
/// left out wasn't kept (the process was idle in every record, or its disk
/// use can't be read), never zero.
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

    init(query: String, from: Date, to: Date, matches: [ProcessHistoryMatch], running: Set<Int64>) {
        self.query = query
        self.from = from
        self.to = to
        processes = matches.map { match in
            let lifetime = match.lifetime
            let summary = match.summary
            return Entry(
                name: lifetime.name, pid: lifetime.identity.pid, startTime: lifetime.identity.startTime, path: lifetime.path,
                user: lifetime.user, bundleID: lifetime.bundleID, launchdLabel: lifetime.jobLabel, restricted: lifetime.isRestricted,
                firstSeen: lifetime.firstSeen, lastSeen: lifetime.lastSeen, ended: lifetime.ended, running: running.contains(match.id),
                records: summary.records, storedRecords: summary.stored, recordedSeconds: summary.recordedSeconds,
                averageCPU: summary.averageCPU, peakCPU: summary.peakCPU, peakMemory: summary.peakMemory,
                averageDiskRead: summary.averageDiskRead, averageDiskWrite: summary.averageDiskWrite
            )
        }
    }
}

func processHistoryList(_ matches: [ProcessHistoryMatch], query: String, range: HistoryRangeOption, running: Set<Int64>,
                        end: Date) -> String {
    guard !matches.isEmpty else { return "Nothing matching \"\(query)\" ran while History was recording in \(range.phrase)." }
    let time = Date.FormatStyle(date: .omitted, time: .standard)
    let dated = Date.FormatStyle(date: .abbreviated, time: .standard)
    func clock(_ date: Date) -> String { date.formatted(Calendar.current.isDateInToday(date) ? time : dated) }
    var lines = ["\(matches.count) \(matches.count == 1 ? "process" : "processes") matching \"\(query)\" in \(range.phrase), "
        + "latest first (CPU: 100% is one core)", ""]
    for match in matches {
        let lifetime = match.lifetime
        let summary = match.summary
        let isRunning = running.contains(match.id)
        let state = isRunning ? "running" : lifetime.ended.map { "ended \(clock($0))" } ?? "last seen \(clock(lifetime.lastSeen))"
        lines.append("\(lifetime.name)  PID \(lifetime.identity.pid)  \(state)")
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
        lines.append("")
    }
    lines.removeLast()
    return lines.joined(separator: "\n")
}
