import Foundation

/// Benchmark results as a file: a versioned JSON envelope around the runs
/// (`BenchmarkRun`) and any comparisons, or the same as Markdown. The
/// Benchmarks workspace's Export and `otm bench --json` write it.
public struct BenchmarkExport: Sendable, Codable, Equatable {
    public static let formatName = "OpenTaskManager benchmark results"
    /// 2 added sustained CPU runs (kind `sustained`, with their windows),
    /// each run's optional `context` and comparisons' `contextWarnings`;
    /// a version 1 file still reads.
    public static let currentVersion = 2

    /// Two runs compared, or why they weren't.
    public struct ComparisonEntry: Sendable, Codable, Equatable {
        /// The earlier run's id, and the later one's.
        public var baseline: String
        public var compared: String
        public var changes: [BenchmarkChange]?
        public var caveats: [String]?
        /// How the runs' starts differed: power, heat, load, memory.
        public var contextWarnings: [BenchmarkContextWarning]?
        /// Why the runs weren't compared, in place of the changes.
        public var refused: String?

        public init(_ first: BenchmarkRun, _ second: BenchmarkRun) {
            let (earlier, later) = first.date <= second.date ? (first, second) : (second, first)
            baseline = earlier.id
            compared = later.id
            switch BenchmarkComparison.compare(earlier, later) {
            case let .compared(comparison):
                changes = comparison.changes
                caveats = comparison.caveats
                contextWarnings = comparison.contextWarnings.isEmpty ? nil : comparison.contextWarnings
            case let .refused(refusal):
                refused = refusal.reason
            }
        }
    }

    public enum ReadError: Error, Equatable {
        case notAnExport
        /// Written by a later version of the format.
        case newerVersion(Int)
    }

    public var format = Self.formatName
    public var version = Self.currentVersion
    public var exported: Date
    /// "OpenTaskManager 0.1.0", "otm 0.1.0".
    public var app: String
    /// Newest first.
    public var runs: [BenchmarkRun]
    public var comparisons: [ComparisonEntry]

    public init(exported: Date, app: String, runs: [BenchmarkRun], comparisons: [(BenchmarkRun, BenchmarkRun)] = []) {
        self.exported = exported
        self.app = app
        self.runs = runs.sorted { $0.date > $1.date }
        self.comparisons = comparisons.map { ComparisonEntry($0, $1) }
    }

    // MARK: - JSON

    /// Pretty-printed, keys sorted, dates in ISO 8601.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads an export back, refusing other JSON and later versions.
    public static func read(_ data: Data) throws -> BenchmarkExport {
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == formatName, let version = header.version else { throw ReadError.notAnExport }
        guard version <= currentVersion else { throw ReadError.newerVersion(version) }
        return try decoder.decode(BenchmarkExport.self, from: data)
    }

    // MARK: - Markdown

    /// A section per test: a table of its runs, the hardware and settings
    /// they ran with, and any comparison of two of them.
    public func markdown(timeZone: TimeZone = .current) -> String {
        let when = Self.dateFormatter(timeZone)
        var lines = [
            "# Benchmark results",
            "",
            "Exported \(when.string(from: exported)) from \(app) · \(runs.count) \(runs.count == 1 ? "run" : "runs").",
        ]
        for kind in BenchmarkKind.allCases {
            let ofKind = runs.filter { $0.kind == kind }
            guard !ofKind.isEmpty else { continue }
            lines += ["", "## \(kind.title)", ""]
            if !kind.measuresThisMac {
                lines += ["These figures measure the Internet connection and the server at the time, not this Mac.", ""]
            }
            lines += table(ofKind, when: when)
            lines += ["", context(ofKind)]
            lines += runNotes(ofKind, when: when)
            for entry in comparisons {
                guard let earlier = ofKind.first(where: { $0.id == entry.baseline }),
                      let later = runs.first(where: { $0.id == entry.compared }) else { continue }
                lines += [""] + comparison(entry, earlier: earlier, later: later, when: when)
            }
        }
        if runs.isEmpty { lines += ["", "No saved runs."] }
        return lines.joined(separator: "\n") + "\n"
    }

    private func table(_ runs: [BenchmarkRun], when: DateFormatter) -> [String] {
        let columns = Self.columns(runs)
        let showsBuild = runs.contains { $0.build != nil }
        let showsTarget = runs.contains { $0.target != nil }
        var header = ["When"]
        var rule = ["---"]
        if showsBuild {
            header.append("Build")
            rule.append("---")
        }
        if showsTarget {
            header.append("On")
            rule.append("---")
        }
        header += columns.map(\.title)
        rule += columns.map { _ in "---:" }
        header.append("Notes")
        rule.append("---")
        var rows = [Self.row(header), Self.row(rule)]
        for run in runs {
            var cells = [when.string(from: run.date)]
            if showsBuild { cells.append(run.build?.title ?? "—") }
            if showsTarget { cells.append(run.target?.name ?? "—") }
            cells += columns.map { column in
                guard let measurement = run.measurement(column.id) else { return "—" }
                return measurement.unit.format(measurement.value) + (measurement.plusMinus.map { " \($0)" } ?? "")
                    + Self.qualifier(measurement.caveat)
            }
            cells.append(run.conditions.joined(separator: "; "))
            rows.append(Self.row(cells))
        }
        return rows
    }

    /// The hardware, workloads and settings behind a test's runs.
    private func context(_ runs: [BenchmarkRun]) -> String {
        var parts: [String] = []
        let machines = Self.unique(runs.compactMap { $0.machine?.name })
        if !machines.isEmpty { parts.append("Measured on \(machines.joined(separator: "; ")).") }
        let versions = Self.unique(runs.map { "v\($0.workloadVersion)" })
        if let kind = runs.first?.kind {
            parts.append("\(kind.versionName.prefix(1).uppercased() + kind.versionName.dropFirst()) \(versions.joined(separator: ", ")).")
        }
        let settings = Self.unique(runs.map(\.settingsSummary)).filter { !$0.isEmpty }
        if !settings.isEmpty { parts.append("Settings: \(settings.joined(separator: "; or ")).") }
        if runs.contains(where: { $0.measurements.contains { $0.spread != nil } }) {
            parts.append("Figures are medians of timed repeats; ± is half the gap between the slowest and fastest.")
        } else {
            parts.append("Each figure is measured once.")
        }
        // What a "(timing unverified)" in the table means, once.
        var caveats: [BenchmarkFigureCaveat] = []
        for caveat in runs.flatMap({ $0.measurements.compactMap(\.caveat) }) where !caveats.contains(caveat) {
            caveats.append(caveat)
        }
        parts += caveats.map { "\($0.title): \($0.explanation)" }
        return parts.joined(separator: " ")
    }

    /// Each run's context, and a sustained run's story, under the table:
    /// "- 2026-10-07 16:11: on the power adapter · thermal nominal · …".
    /// Nothing when no run of the test recorded its context.
    private func runNotes(_ runs: [BenchmarkRun], when: DateFormatter) -> [String] {
        guard runs.contains(where: { $0.context != nil || $0.sustained != nil }) else { return [] }
        return ["", "Each run's context (what the Mac was doing as it started):", ""] + runs.map { run in
            "- \(when.string(from: run.date)): \(run.contextSummary)" + (run.sustained?.narrative.map { ". \($0)" } ?? "")
        }
    }

    /// " (timing unverified)" after a figure in doubt, else nothing.
    private static func qualifier(_ caveat: BenchmarkFigureCaveat?) -> String {
        caveat.map { " (\($0.title.lowercased()))" } ?? ""
    }

    private func comparison(_ entry: ComparisonEntry, earlier: BenchmarkRun, later: BenchmarkRun, when: DateFormatter) -> [String] {
        let span = "\(when.string(from: earlier.date)) → \(when.string(from: later.date))"
        guard let changes = entry.changes else {
            return ["### Not compared: \(span)", "", entry.refused ?? ""]
        }
        var lines = [
            "### Compared: \(span)",
            "",
            Self.row(["Figure", "Earlier", "Later", "Change", "Spread", "Verdict"]),
            Self.row(["---", "---:", "---:", "---:", "---", "---"]),
        ]
        for change in changes {
            lines.append(Self.row([
                change.title, change.unit.format(change.baseline) + Self.qualifier(change.baselineCaveat),
                change.unit.format(change.compared) + Self.qualifier(change.comparedCaveat),
                change.change.map(BenchmarkChange.formatChange) ?? "—", change.spreadText, change.verdict.title.lowercased(),
            ]))
        }
        if let caveats = entry.caveats, !caveats.isEmpty {
            lines += [""] + caveats.map { "- \($0)" }
        }
        if let warnings = entry.contextWarnings, !warnings.isEmpty {
            lines += ["", "How the runs' starts differed:", ""] + warnings.map { "- \($0.text)" }
        }
        return lines
    }

    /// The figures every run of a test has, in the newest run's order.
    private static func columns(_ runs: [BenchmarkRun]) -> [BenchmarkMeasurement] {
        var columns: [BenchmarkMeasurement] = []
        for run in runs {
            for measurement in run.measurements where !columns.contains(where: { $0.id == measurement.id }) {
                columns.append(measurement)
            }
        }
        return columns
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: [String] = []
        for value in values where !seen.contains(value) {
            seen.append(value)
        }
        return seen
    }

    static func percent(_ fraction: Double) -> String {
        Format.percent(fraction, digits: abs(fraction) < 0.1 ? 1 : 0)
    }

    private static func dateFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

public extension BenchmarkMeasurement {
    /// Half the slowest-to-fastest spread, as the cards show it: "±1.2%";
    /// nil for a figure measured once.
    var plusMinus: String? {
        spread.map { "±\(BenchmarkExport.percent($0 / 2))" }
    }
}

public extension BenchmarkChange {
    /// "+4.2%", "−3.1%", "+12%": a sign always, a decimal under 10%.
    static func formatChange(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let text = BenchmarkExport.percent(abs(fraction))
        if text == BenchmarkExport.percent(0) { return text }
        return (fraction < 0 ? "−" : "+") + text
    }

    /// Each run's ± (half its slowest-to-fastest spread): "±0.9% / ±1.2%",
    /// or "—" for a figure measured once, whose verdict says so.
    var spreadText: String {
        guard let baselineSpread, let comparedSpread else { return "—" }
        return "±\(BenchmarkExport.percent(baselineSpread / 2)) / ±\(BenchmarkExport.percent(comparedSpread / 2))"
    }
}

public extension BenchmarkChange.Verdict {
    var title: String {
        switch self {
        case .better: "Better"
        case .worse: "Worse"
        case .withinSpread: "Within spread"
        case .negligible: "Negligible"
        case .measuredOnce: "Measured once"
        case .unchanged: "Unchanged"
        }
    }

    /// What the verdict means, for a tooltip or a footnote.
    var explanation: String {
        switch self {
        case .better: "It moved the good way, past both runs' spread from slowest to fastest repeat."
        case .worse: "It moved the bad way, past both runs' spread from slowest to fastest repeat."
        case .withinSpread: "The two runs' ranges of repeats overlap, so the difference could be noise."
        case .negligible: "It moved past both runs' spread, but by less than 1%: too little to matter."
        case .measuredOnce: "This test measures each figure once, so there's no spread to tell noise from change."
        case .unchanged: "The same figure in both runs."
        }
    }
}
