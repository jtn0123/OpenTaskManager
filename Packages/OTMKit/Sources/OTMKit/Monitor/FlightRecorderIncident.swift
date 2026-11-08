import Foundation
import SQLite3

extension FlightRecorder {
    public func latestIncidentMoment() throws(FlightRecorderError) -> Date? {
        // The primary time index supplies its last entry; the actor owns and finalizes the statement.
        let statement = unsafe try Self.prepare("SELECT time FROM records ORDER BY time DESC LIMIT 1", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        let status = unsafe sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// One snapshot, no suspension or sampling work, including when a read-only CLI opens it.
    public func incident(_ window: IncidentWindow, limit: Int = 200, reportFolders: [URL] = ProcessDiagnosticReports.folders)
        throws(FlightRecorderError) -> IncidentTimeline {
        let limit = min(max(limit, 1), 200)
        // The actor owns the connection; a transaction keeps another app copy's writes out of this evidence snapshot.
        unsafe try Self.execute("BEGIN", on: database)
        do throws(FlightRecorderError) {
            let lifetimes = try processLifetimes(from: window.start, to: window.end, limit: limit + 1)
            let resources = try incidentResources(window, limit: limit)
            let processes = try incidentProcesses(window, lifetimes: Array(lifetimes.prefix(limit)),
                                                  cut: lifetimes.count > limit, limit: limit, reportFolders: reportFolders)
            let jobs = try incidentJobs(window, lifetimes: lifetimes, limit: limit)
            let sockets = try incidentSockets(window, lifetimes: lifetimes, limit: limit)
            let events = try events(from: window.start, to: window.end, limit: limit + 1)
            let coverage = try incidentCoverage(window, source: .events, limit: limit)
            let eventRows = events.enumerated().map { index, event in
                IncidentRow(id: "event/\(index)", time: event.time,
                    title: event.kind.incidentWords + (event.name.isEmpty ? "" : " · \(event.name)"),
                    detail: (event.endAction?.words ?? event.detail) + (event.isApproximate ? " · Approximate observation" : "")
                        + (event.count > 1 ? " · \(event.count) together" : ""), kind: event.kind.rawValue)
            }
            let eventCoverage = IncidentCoverage(window: window,
                spans: (coverage[""]?.spans ?? []) + events.prefix(limit).map { .init(start: $0.time, end: $0.time) },
                cut: coverage[""]?.cut == true, inferred: true)
            let eventLane = IncidentLane(kind: .events, rows: eventRows, coverage: eventCoverage,
                                         limit: limit,
                                         note: "Coverage uses resource recording spans; event observer coverage is not stored separately.")
            unsafe try Self.execute("COMMIT", on: database)
            return IncidentTimeline(window: window, lanes: [resources, processes, jobs, sockets, eventLane])
        } catch {
            unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func incidentResources(_ window: IncidentWindow, limit: Int) throws(FlightRecorderError) -> IncidentLane {
        let current = try stats(from: window.start, to: window.end, limit: limit)
        let baseline = try stats(from: window.baseline.start, to: window.baseline.end, limit: limit)
        let coverage = try incidentCoverage(window, source: .resources, limit: limit)
        let previous = try incidentCoverage(window.baseline, source: .resources, limit: limit)
        let watched = coverage[""] ?? IncidentCoverage(window: window, spans: [])
        let baselineWatched = previous[""] ?? IncidentCoverage(window: window.baseline, spans: [])
        var rows: [IncidentRow] = []
        for metric in [HistoryMetric.cpu, .memory, .diskRead, .diskWrite, .networkIn, .networkOut] {
            guard let figure = current.figures[metric] else { continue }
            let before = baseline.figures[metric]
            let name = ["cpu": "CPU", "memory": "Memory", "diskRead": "Disk read", "diskWrite": "Disk write",
                        "networkIn": "Network in", "networkOut": "Network out"][metric.rawValue] ?? metric.rawValue
            let value = incidentValue(figure.average, metric: metric)
            let prior = before.map { incidentValue($0.average, metric: metric) } ?? "not recorded"
            let rose = metric == .cpu && before.map { figure.average > $0.average + 0.1 } == true
            rows.append(IncidentRow(id: "resource/\(name)", time: window.end, title: "\(name): \(value) (was \(prior))",
                detail: "Average over recorded time · was: the 10 minutes before, \(baselineWatched.words.lowercased())",
                kind: rose ? "cpuRose" : name))
        }
        let pressure = try incidentPressure(window, limit: limit)
        let oldPressure = try incidentPressure(window.baseline, limit: limit)
        if let pressure {
            rows.append(IncidentRow(id: "resource/pressure", time: window.end,
                title: "Memory pressure: \(pressure) (was \(oldPressure ?? "not recorded"))",
                detail: "Recorded unavailable-memory share; not a categorical warning level"))
        }
        // The five busiest that read above zero, as the Overview's top lists keep.
        let top = try topCPU(from: window.start, to: window.end, count: min(limit, 5)).filter { $0.value >= 0.05 }
        rows += top.enumerated().map { index, app in
            IncidentRow(id: "busy/\(index)", time: window.end, title: app.name,
                detail: "Busiest recorded CPU list · \(unsafe String(format: "%.1f", app.value))% of one core · names aggregated by recorder",
                kind: index == 0 ? "busiest" : "busy")
        }
        return IncidentLane(kind: .resources, rows: rows, coverage: watched, limit: limit, cut: watched.cut,
                            note: "Averages exclude gaps. If cut, figures summarize the first \(limit) records; busiest names span the window.")
    }

    // C varargs borrow only these finite recorded numbers for the formatting call.
    private func incidentValue(_ value: Double, metric: HistoryMetric) -> String {
        metric.isFraction ? unsafe String(format: "%.1f%%", value * 100) : Format.bytesPerSecond(value)
    }

    private func incidentPressure(_ window: IncidentWindow, limit: Int) throws(FlightRecorderError) -> String? {
        // SQLite aggregates only the bounded indexed records; the actor owns and finalizes the statement.
        let statement = unsafe try Self.prepare("""
            SELECT AVG(pressure) FROM (SELECT pressure FROM records WHERE time > ?1 AND time <= ?2 ORDER BY time LIMIT ?3)
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, window.start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, window.end.timeIntervalSince1970)
        unsafe sqlite3_bind_int64(statement, 3, Int64(limit))
        guard unsafe sqlite3_step(statement) == SQLITE_ROW else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        guard unsafe sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return unsafe String(format: "%.1f%%", sqlite3_column_double(statement, 0) * 100)
    }

    private func incidentProcesses(_ window: IncidentWindow, lifetimes: [ProcessLifetime], cut: Bool,
                                   limit: Int, reportFolders: [URL]) throws(FlightRecorderError) -> IncidentLane {
        var rows: [IncidentRow] = []
        var loaded = 0
        var evidenceCut = false
        for lifetime in lifetimes {
            let details = "PID \(lifetime.identity.pid) · start \(lifetime.identity.startTime?.ISO8601Format() ?? "not recorded")"
                + (lifetime.path.map { " · \($0)" } ?? "") + " · user: \(lifetime.user)"
            if window.contains(lifetime.started) {
                rows.append(IncidentRow(id: "process/\(lifetime.id)/start", time: lifetime.started,
                    title: "\(lifetime.name) started", detail: details, process: lifetime.identity, lifetime: lifetime.id, kind: "started",
                    user: lifetime.user))
            }
            if let end = lifetime.ended, window.contains(end) {
                let ending: String
                var endingEvidence: ProcessEnding?
                if loaded < 20 {
                    let evidence = try processEnding(lifetime, reportFolders: reportFolders, limit: limit)
                    endingEvidence = evidence
                    evidenceCut = evidenceCut || evidence.evidenceCut == true
                    ending = evidence.words(clock: { $0.ISO8601Format() }).joined(separator: "\n")
                        + (evidence.evidenceCut == true ? "\nEnding evidence cut · further source rows may exist" : "")
                    loaded += 1
                } else { ending = "Evidence not loaded · only the first 20 ended lifetimes are inspected" }
                rows.append(IncidentRow(id: "process/\(lifetime.id)/end", time: end, title: "\(lifetime.name) ended",
                    detail: details + "\n" + ending, process: lifetime.identity, lifetime: lifetime.id, kind: "ended",
                    user: lifetime.user, ending: endingEvidence))
            }
        }
        let coverage = try incidentCoverage(window, source: .processes, limit: limit)
        return IncidentLane(kind: .processes, rows: rows, coverage: coverage[""] ?? .init(window: window, spans: []),
                            limit: limit, cut: cut || evidenceCut, note: "Observed starts and ends; short runs may be counted without an identity.")
    }

    private func incidentJobs(_ window: IncidentWindow, lifetimes: [ProcessLifetime], limit: Int)
        throws(FlightRecorderError) -> IncidentLane {
        let events = try launchJobEvents(from: window.start, to: window.end, limit: limit + 1)
        var domains = try incidentCoverage(window, source: .jobs, limit: limit)
        let coverageCut = domains.values.contains { $0.cut }
        for domain in Set(events.map(\.key.domain)).union(["system", "gui/\(getuid())"]) where domains[domain] == nil {
            domains[domain] = IncidentCoverage(window: window, spans: [], cut: coverageCut)
        }
        let rows = events.map { event in
            let lifetime = IncidentTimeline.lifetime(for: event.kind == .exited ? event.exitedIdentity : event.observedIdentity, in: lifetimes)
            return IncidentRow(id: "job/\(event.id)", time: event.time, title: "\(event.key.label) · \(event.words)",
                detail: "\(event.key.domain) · observed"
                    + (event.since.map { " between \($0.ISO8601Format()) and \(event.time.ISO8601Format())" } ?? ""),
                process: lifetime?.identity, lifetime: lifetime?.id, job: event.key, kind: event.kind.rawValue)
        }
        var common = [LaunchHistoryInterval(start: window.start, end: window.end)]
        for domain in domains.values {
            common = common.flatMap { left in
                domain.spans.compactMap { right in
                    let start = max(left.start, right.start)
                    let end = min(left.end, right.end)
                    return start <= end ? LaunchHistoryInterval(start: start, end: end) : nil
                }
            }
        }
        let coverage = IncidentCoverage(window: window, spans: common, cut: coverageCut,
            note: "Spans watched in every launchd domain; separate domain coverage follows.")
        return IncidentLane(kind: .jobs, rows: rows, coverage: coverage, domains: domains, limit: limit,
                            note: "Transitions are observation times. No attribution from label or PID alone.")
    }

    private func incidentSockets(_ window: IncidentWindow, lifetimes: [ProcessLifetime], limit: Int) throws(FlightRecorderError) -> IncidentLane {
        let sockets = try incidentConnections(window, limit: limit + 1)
        var rows: [IncidentRow] = []
        for row in sockets.prefix(limit) {
            let connection = row.socket.connection
            let lifetime = IncidentTimeline.lifetime(for: connection.process, in: lifetimes)
            let detail = "\(connection.local.formatted) → \(connection.remote?.formatted ?? "No remote endpoint")"
                + " · PID \(connection.pid) · \(row.id)"
            func entry(_ time: Date, kind: String) -> IncidentRow {
                IncidentRow(id: "socket/\(row.id)/\(kind)", time: time, title: "\(row.process.name) · socket \(kind)", detail: detail,
                    process: connection.process, lifetime: lifetime?.id, socket: row.id, port: connection.local.port,
                    transport: connection.transport.rawValue, remoteAddress: connection.remote?.address, kind: kind, user: row.process.user)
            }
            if window.contains(row.socket.firstSeen) { rows.append(entry(row.socket.firstSeen, kind: "opened")) }
            if row.ending == .closed, let end = row.closedBy, window.contains(end) { rows.append(entry(end, kind: "closed")) }
        }
        let changes = try incidentListenerChanges(window, limit: limit + 1)
        for (index, change) in changes.prefix(limit).enumerated() {
            let connection = change.listener.connection
            let lifetime = IncidentTimeline.lifetime(for: connection.process, in: lifetimes)
            // A widened bind or a port changing hands is a change, not always a new listener; the reasons follow.
            rows.append(IncidentRow(id: "listener/\(index)", time: change.detectedAt,
                title: "\(connection.processName) · listener change on \(change.id.portLabel(seen: connection.local.port))",
                detail: change.reasons.map(\.label).joined(separator: " · ") + " · \(change.listener.identity.executable.path)",
                process: connection.process, lifetime: lifetime?.id, port: connection.local.port,
                transport: connection.transport.rawValue, kind: "listener"))
        }
        let socketCoverage = try connectionCoverage(from: window.start, to: window.end, limit: limit + 1)
        let coverage = IncidentCoverage(window: window, spans: socketCoverage.intervals.prefix(limit).map {
            LaunchHistoryInterval(start: $0.start, end: $0.end)
        }, cut: socketCoverage.intervals.count > limit)
        return IncidentLane(kind: .sockets, rows: rows, coverage: coverage,
            limit: limit, cut: sockets.count > limit || changes.count > limit,
            note: "Socket walks may miss short-lived sockets. Hidden processes: \(socketCoverage.intervals.map(\.hiddenProcesses).max() ?? 0). "
                + "Retention dropped \(socketCoverage.droppedRows) rows. Listener changes are pending reviews only.")
    }
}
