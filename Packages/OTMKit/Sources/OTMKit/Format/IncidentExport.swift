import Foundation

/// Both formats pass through the same redaction, including copies of rows in sequence evidence.
public struct IncidentExport: Sendable {
    public let timeline: IncidentTimeline
    public let includesPrivateDetails: Bool
    public let home: String
    public let user: String

    public init(_ timeline: IncidentTimeline, includesPrivateDetails: Bool = false,
                home: String = NSHomeDirectory(), user: String = NSUserName()) {
        self.timeline = timeline
        self.includesPrivateDetails = includesPrivateDetails
        self.home = home
        self.user = user
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = (try JSONSerialization.jsonObject(with: encoder.encode(timeline))) as? [String: Any] ?? [:]
        object["format"] = "OpenTaskManager incident evidence"
        object["includesPrivateDetails"] = includesPrivateDetails
        return try JSONSerialization.data(withJSONObject: redactObject(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public func markdown() -> String {
        var lines = ["# Incident evidence", "", "\(timeline.window.start.ISO8601Format()) — \(timeline.window.end.ISO8601Format())", "",
                     includesPrivateDetails ? "Private details included." : "Home paths, user names and remote addresses redacted.", "",
                     "## Happened together", "", "Sequences describe observations together, never causes.", ""]
        if timeline.fixture { lines += ["Made-up fixture; no recorder data was saved.", ""] }
        if timeline.sequences.isEmpty { lines += ["No sequence found in the loaded evidence.", ""] }
        for sequence in timeline.sequences {
            lines.append("- \(escape(sequence.label))")
            for row in sequence.evidence { lines.append("  - \(row.time.ISO8601Format()) · \(escape(row.title)) · \(escape(row.detail))") }
        }
        for lane in timeline.lanes {
            lines += ["", "## \(lane.kind.rawValue)", "", lane.domains.isEmpty ? lane.coverage.words : "Coverage by launchd domain:",
                      escape(lane.note), ""]
            if lane.cut { lines += ["Lane cut: first \(lane.rows.count) rows loaded; further evidence may exist.", ""] }
            appendCoverage(lane.coverage, to: &lines)
            for domain in lane.domains.keys.sorted() {
                if let coverage = lane.domains[domain] {
                    lines.append("\(domain): \(coverage.words)")
                    appendCoverage(coverage, to: &lines)
                }
            }
            if lane.rows.isEmpty { lines.append("No rows in the loaded evidence. \(lane.coverage.words).") }
            for row in lane.rows {
                lines.append("- \(row.time.ISO8601Format()) · \(escape(row.title)) · \(escape(row.detail))")
                if let process = row.process {
                    lines.append("  - Identity: PID \(process.pid), start \(process.startTime?.ISO8601Format() ?? "unknown")")
                }
                if let job = row.job { lines.append("  - Job: \(escape(job.domain))/\(escape(job.label))") }
                if let socket = row.socket { lines.append("  - Socket lifetime: \(escape(socket))") }
                for evidence in row.ending?.evidence ?? [] {
                    lines.append("  - Source: \(evidence.source.rawValue) · \(evidence.time.ISO8601Format()) · \(escape(evidence.summary))")
                    if let report = evidence.report { lines.append("  - Report: \(escape(report.path))") }
                }
            }
        }
        return redact(lines.joined(separator: "\n")) + "\n"
    }

    private func appendCoverage(_ coverage: IncidentCoverage, to lines: inout [String]) {
        for span in coverage.spans { let label = coverage.inferred ? "Recording / event sighting" : "Watched"
            lines.append("- \(label): \(span.start.ISO8601Format()) — \(span.end.ISO8601Format())") }
        if !coverage.note.isEmpty { lines.append(escape(coverage.note)) }
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " · ").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "<", with: "&lt;")
    }

    private func redactObject(_ value: Any) -> Any {
        if let text = value as? String { return redact(text) }
        if let values = value as? [Any] { return values.map(redactObject) }
        if let values = value as? [String: Any] { return values.mapValues(redactObject) }
        return value
    }

    public func redact(_ text: String) -> String {
        guard !includesPrivateDetails else { return text }
        var result = text
        let rows = timeline.lanes.flatMap(\.rows) + timeline.sequences.flatMap(\.evidence)
        for address in Set(rows.compactMap(\.remoteAddress)).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: address, with: Self.maskAddress(address))
        }
        if !home.isEmpty { result = result.replacingOccurrences(of: home, with: "~") }
        result = result.replacingOccurrences(of: #"/Users/[^/\s\\\"·]+"#, with: "~", options: .regularExpression)
        result = result.replacingOccurrences(of: #"user: [^·\n]+"#, with: "user: [redacted] ", options: .regularExpression)
        for name in Set(rows.compactMap(\.user) + [user]) where !name.isEmpty {
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    public static func maskAddress(_ address: String) -> String {
        let address = String(address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let ipv4 = address.split(separator: ".")
        if ipv4.count == 4, ipv4.allSatisfy({ UInt8($0) != nil }) { return ipv4.prefix(3).joined(separator: ".") + ".0/24" }
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return "[masked remote]" }
        let left = halves[0].split(separator: ":").map(String.init)
        let right = halves.count == 2 ? halves[1].split(separator: ":").map(String.init) : []
        let groups = halves.count == 2 ? left + Array(repeating: "0", count: max(0, 8 - left.count - right.count)) + right : left
        guard groups.count == 8, groups.allSatisfy({ UInt16($0, radix: 16) != nil }) else { return "[masked remote]" }
        return groups.prefix(3).map { String(UInt16($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":") + "::/48"
    }
}
