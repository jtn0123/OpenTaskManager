import OTMKit
import SwiftUI

/// History's process search, the lifetime picked from it, and that
/// lifetime's figures over the range shown: shared by the Processes
/// section, the rail's process lane and the moment panel, and kept across
/// visits to the page. It reads the recorder only when the search, the
/// pick, the range or a new graph point asks, never per tick.
@Observable
@MainActor
final class HistoryProcessStore {
    static let shared = HistoryProcessStore()
    /// Lifetimes a search lists at most, latest first.
    static let limit = 50

    /// What a search found, and what it was for.
    struct Results: Equatable {
        let query: String
        let matches: [ProcessHistoryMatch]
        /// Those running now, by lifetime.
        let running: Set<Int64>
    }

    /// The lifetime picked, with its points over the range shown.
    struct Track: Equatable {
        let match: ProcessHistoryMatch
        /// Its points as the page's charts take them (`HistoryProcessKey`'s figures).
        let points: [HistoryPoint]
        /// The same points as read, for the moment panel.
        let figures: [ProcessHistoryPoint]
        /// Where every record left it out as idle.
        let idle: [ClosedRange<Date>]
        /// Where it ran but an older build, keeping no process history, recorded.
        let unwatched: [ClosedRange<Date>]
        /// Whether it's the process running now with its PID.
        let isRunning: Bool
        let bucket: TimeInterval
        let domain: ClosedRange<Date>

        var lifetime: ProcessLifetime { match.lifetime }

        /// The stretch it ran within the range: to now while it runs.
        var span: ClosedRange<Date>? {
            lifetime.span(within: domain, isRunning: isRunning, now: domain.upperBound)
        }
    }

    /// The search field's text.
    var query = ""
    /// Counts requests from elsewhere, so one for the query already shown
    /// still runs the search again.
    private(set) var requests = 0
    private(set) var results: Results?
    /// The lifetime picked from the results, by identity, so a new range
    /// reads it again; nil shows the results.
    private(set) var picked: ProcessIdentity?
    private(set) var track: Track?
    /// A lifetime to pick once a search finds it (the inspector's Show
    /// History), or for `-openProcessHistory`, the first found.
    @ObservationIgnored private var pending: Pending?

    private enum Pending {
        case identity(ProcessIdentity)
        case first
    }

    private init() {
        // `-openProcessHistory <query>` searches History for it and picks the latest found, for screenshots.
        if let query = LaunchArgument.string("openProcessHistory") {
            self.query = query
            pending = .first
        }
    }

    /// Searches for `query`, picking `identity` once found: the process
    /// inspector's Show History.
    func show(_ query: String, identity: ProcessIdentity) {
        self.query = query
        pending = .identity(identity)
        requests += 1
        unpick()
    }

    func pick(_ match: ProcessHistoryMatch) {
        guard picked != match.lifetime.identity else { return }
        picked = match.lifetime.identity
        track = nil
    }

    /// Back to the results.
    func unpick() {
        picked = nil
        track = nil
    }

    /// Clears the search and the pick.
    func clear() {
        query = ""
        results = nil
        unpick()
    }

    /// Runs the search over `domain` in `recorder`. `isRunning` tells a
    /// lifetime still running in this app (never for a recording file).
    func search(in recorder: FlightRecorder, domain: ClosedRange<Date>, isRunning: (ProcessIdentity) -> Bool) async {
        let text = query
        guard ProcessHistorySearch.normalized(text) != nil else {
            if results != nil { results = nil }
            return
        }
        let found = (try? await recorder.processLifetimes(matching: text, from: domain.lowerBound, to: domain.upperBound,
                                                          limit: Self.limit)) ?? []
        guard !Task.isCancelled, text == query else { return }
        let running = Set(found.filter { isRunning($0.lifetime.identity) }.map(\.id))
        let next = Results(query: text, matches: found, running: running)
        if results != next { results = next }
        switch pending {
        case .identity(let identity):
            if let match = found.first(where: { $0.lifetime.identity == identity }) { pick(match) }
            pending = nil
        case .first:
            if let match = found.first { pick(match) }
            pending = nil
        case nil:
            break
        }
    }

    /// Reads the picked lifetime's points over `domain`, `bucket` seconds each.
    func load(from recorder: FlightRecorder, domain: ClosedRange<Date>, bucket: TimeInterval, isRunning: (ProcessIdentity) -> Bool) async {
        guard let identity = picked else { return }
        guard let lifetime = try? await recorder.processLifetime(identity) else {
            if !Task.isCancelled, picked == identity { unpick() }
            return
        }
        let summary = (try? await recorder.processSummary(lifetime, from: domain.lowerBound, to: domain.upperBound)) ?? .empty
        let figures = (try? await recorder.processPoints(lifetime, from: domain.lowerBound, to: domain.upperBound, bucket: bucket)) ?? []
        let unwatched = (try? await recorder.processUnwatched(lifetime, from: domain.lowerBound, to: domain.upperBound,
                                                              bucket: bucket)) ?? []
        guard !Task.isCancelled, picked == identity else { return }
        let next = Track(match: ProcessHistoryMatch(lifetime: lifetime, summary: summary), points: figures.map(HistoryProcessKey.point),
                         figures: figures, idle: ProcessHistoryPoint.idleStretches(figures, bucket: bucket), unwatched: unwatched,
                         isRunning: isRunning(identity), bucket: bucket, domain: domain)
        if track != next { track = next }
    }
}

/// Where a process's figures sit among a `HistoryPoint`'s values, so its
/// charts draw with the page's own lines, breaks and dots: none where a
/// point is idle, so a line breaks there rather than drop to zero.
enum HistoryProcessKey {
    /// Percent of one core.
    static let cpu = "process.cpu"
    static let cpuPeak = "process.cpuPeak"
    /// Bytes.
    static let memory = "process.memory"
    /// Bytes a second.
    static let diskRead = "process.diskRead"
    static let diskWrite = "process.diskWrite"

    static func point(_ point: ProcessHistoryPoint) -> HistoryPoint {
        var values = HistoryValues()
        values.hardware[cpu] = point.cpu
        values.hardware[cpuPeak] = point.cpuPeak
        values.hardware[memory] = point.memory
        values.hardware[diskRead] = point.diskRead
        values.hardware[diskWrite] = point.diskWrite
        return HistoryPoint(time: point.time, values: values, segment: point.segment)
    }
}

/// How the History page draws a process's lifetime.
enum HistoryProcessStyle {
    /// The lifetime's lane on the rail, and its marks.
    static let tint = Color.purple

    /// The dimming before it started and after it ended.
    static func notRunning(dark: Bool) -> Color {
        Color.black.opacity(dark ? 0.26 : 0.07)
    }

    /// The wash over a stretch where it ran idle, not stored.
    static func idle(dark: Bool) -> Color {
        tint.opacity(dark ? 0.16 : 0.09)
    }

    /// "Running", "Ended 10:42 AM" or "Last seen 10:42 AM" (one that went
    /// unwatched, or ended while nothing recorded).
    static func state(_ lifetime: ProcessLifetime, isRunning: Bool) -> String {
        if isRunning { return "Running" }
        if let ended = lifetime.ended { return "Ended \(clock(ended))" }
        return "Last seen \(clock(lifetime.lastSeen))"
    }

    /// "10:42 AM", with seconds, and the weekday before today.
    static func clock(_ time: Date) -> String {
        var style: Date.FormatStyle = .dateTime.hour().minute().second()
        if !Calendar.current.isDateInToday(time) { style = style.weekday(.abbreviated) }
        return time.formatted(style)
    }

    /// When it ran within the range: "10:02 – 10:42 AM · 40 min".
    static func span(_ span: ClosedRange<Date>) -> String {
        HistorySessionStyle.span(span.lowerBound, span.upperBound) + " · " + Format.roughDuration(span.upperBound.timeIntervalSince(span.lowerBound))
    }

    /// Its figures over the range, on the page's CPU scale: "CPU avg 3.2%,
    /// peak 45% · Memory peak 1.2 GB", or why there are none.
    static func figures(_ summary: ProcessHistorySummary, scale: CPUScale) -> String {
        guard summary.records > 0 else { return "Not recorded while it ran" }
        guard let average = summary.averageCPU, let peak = summary.peakCPU else { return "Idle throughout, not stored" }
        var parts = ["CPU avg \(scale.format(average)), peak \(scale.format(peak))"]
        if let memory = summary.peakMemory { parts.append("Memory peak \(Format.bytes(memory))") }
        return parts.joined(separator: " · ")
    }

    /// What "idle, not stored" means, for tooltips.
    static let idleHelp = "Idle, not stored: it ran, but under every keep threshold (CPU under "
        + "\(Format.fixed(ProcessHistoryKeep.cpuFloor, 1))% of one core, disk under \(Int(ProcessHistoryKeep.diskFloor / 1_024)) KB/s, "
        + "and not among the \(ProcessHistoryKeep.memoryTop) largest in memory), so its figures weren't kept. "
        + "It's never drawn as zero; averages count it as nothing."
}
