import Foundation

/// One test's saved runs as trends, for the Benchmarks workspace's charts.
/// The runs split into lines by `BenchmarkComparison`'s rules, so only runs
/// that can be compared (same workloads, kind of build, hardware, volume or
/// interface, and settings) share a line; each figure then has a point per
/// run, with its recorded spread and any doubt over its timing. With a
/// baseline picked, every run it can be compared with carries its change
/// from it and the verdict a comparison of the two would give.
public struct BenchmarkTrend: Sendable, Equatable {
    /// Runs that can all be compared with each other.
    public struct Line: Sendable, Equatable, Identifiable {
        /// 0 for the line with the newest run, then by their newest runs.
        public var id: Int
        /// What sets this line's runs apart from the other lines' (only what
        /// differs between them): "Debug build", "workloads v2 · Release build",
        /// "Macintosh HD". Empty when every run is on one line.
        public var title: String
        /// Oldest first.
        public var runIDs: [String]
    }

    /// One run's figure on a chart.
    public struct Point: Sendable, Equatable, Identifiable {
        public var runID: String
        /// The line the run is on.
        public var line: Int
        /// Where the run falls among all the test's runs, oldest 0: the
        /// charts' shared x axis, so the lines' runs interleave as they ran.
        public var sequence: Int
        public var date: Date
        public var value: Double
        /// The slowest and fastest repeats; nil when the test measures once.
        public var low: Double?
        public var high: Double?
        public var repeats: Int?
        public var caveat: BenchmarkFigureCaveat?
        /// The change from the baseline, when one is picked and this run can be
        /// compared with it. The baseline's own point has it too, unchanged.
        public var fromBaseline: BenchmarkChange?
        public var isBaseline: Bool

        public var id: String { runID }
    }

    /// One figure's points over the runs, oldest first.
    public struct Figure: Sendable, Equatable, Identifiable {
        /// The measurement's id: "integer.multi", "sequentialRead".
        public var id: String
        /// "Integer, 6 workers".
        public var title: String
        public var unit: BenchmarkUnit
        public var points: [Point]
        /// The scale its figures read in ("MB/s", divided by 1e6).
        public var scaleUnit: String
        public var divisor: Double
        /// The range the chart spans: every point's spread, padded, and never
        /// so narrow that noise fills the plot (`minimumSpan`).
        public var domain: ClosedRange<Double>
        /// Where the axis is labelled, in the figures' own units: round
        /// values in `scaleUnit` (`ticks(_:divisor:)`).
        public var ticks: [Double]
        /// Decimals the labels need to read exactly in `scaleUnit`.
        public var tickDecimals: Int

        /// A tick in `scaleUnit`, without the unit: "106", "5.4", "12,500".
        public func tickLabel(_ value: Double) -> String {
            let scaled = value / divisor
            return tickDecimals == 0 ? Int(scaled.rounded()).formatted() : Format.fixed(scaled, tickDecimals)
        }

        /// The baseline's point, when it has this figure.
        public var baseline: Point? {
            points.first(where: \.isBaseline)
        }

        /// The newest run, other than the baseline, that can be compared with
        /// the baseline: its point carries the change. Nil without a baseline.
        public var latestCompared: Point? {
            points.last { !$0.isBaseline && $0.fromBaseline != nil }
        }

        /// Whether any run recorded a spread to draw.
        public var hasSpread: Bool {
            points.contains { $0.low != nil && $0.high != nil }
        }
    }

    public var kind: BenchmarkKind
    public var lines: [Line]
    public var figures: [Figure]
    /// The runs' dates, oldest first: the x axis.
    public var dates: [Date]
    /// The baseline's run id, when it's among the runs.
    public var baseline: String?

    /// The narrowest a chart's range gets, as a share of its figures' middle:
    /// 5%, so a 1% move (`BenchmarkChange.negligibleChange`) takes a fifth of
    /// the plot rather than all of it.
    public static let minimumSpan = 0.05

    /// `runs` of one test, any order. A `baseline` that isn't among them is ignored.
    public init(runs: [BenchmarkRun], baseline: String? = nil) {
        let ordered = runs.sorted { $0.date < $1.date }
        kind = ordered.first?.kind ?? .cpu
        dates = ordered.map(\.date)
        let base = ordered.first { $0.id == baseline }
        self.baseline = base?.id
        let lines = Self.lines(ordered)
        self.lines = lines
        var lineOf: [String: Int] = [:]
        for line in lines {
            for id in line.runIDs { lineOf[id] = line.id }
        }
        let comparable = base.map { base in Set(ordered.filter { BenchmarkComparison.refusal(base, $0) == nil }.map(\.id)) } ?? []
        figures = Self.measurementIDs(ordered).compactMap { id in
            Self.figure(id, runs: ordered, lineOf: lineOf, baseline: base, comparable: comparable)
        }
    }

    // MARK: - Lines

    /// Runs sorted oldest first, split into lines of runs that can be
    /// compared: a run joins the first line whose first run it can be
    /// compared with. Lines go newest first, each named by what sets it apart.
    static func lines(_ runs: [BenchmarkRun]) -> [Line] {
        var groups: [[BenchmarkRun]] = []
        for run in runs {
            if let index = groups.firstIndex(where: { BenchmarkComparison.refusal($0[0], run) == nil }) {
                groups[index].append(run)
            } else {
                groups.append([run])
            }
        }
        groups.sort { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
        let titles = titles(groups.map { $0[0] })
        return groups.indices.map { Line(id: $0, title: titles[$0], runIDs: groups[$0].map(\.id)) }
    }

    /// A title for each line from its first run, naming only what differs
    /// between the lines: the workloads' version, the kind of build, the
    /// hardware, the volume or interface, then any setting.
    static func titles(_ firsts: [BenchmarkRun]) -> [String] {
        guard firsts.count > 1 else { return firsts.map { _ in "" } }
        let parts: [(BenchmarkRun) -> String?] = [
            { $0.kind.versionName.prefix(1).uppercased() + $0.kind.versionName.dropFirst() + " v\($0.workloadVersion)" },
            { $0.build.map { "\($0.title) build" } },
            { $0.machine?.name },
            { $0.target?.name },
        ]
        let settingNames = unique(firsts.flatMap { $0.settings.map(\.name) })
        let settings = settingNames.map { name -> (BenchmarkRun) -> String? in
            { run in run.settings.first { $0.name == name }.map { "\($0.name) \($0.value)" } ?? "No \(name.lowercased())" }
        }
        let differing = (parts + settings).filter { part in Set(firsts.map { part($0) ?? "" }).count > 1 }
        return firsts.indices.map { index in
            let title = differing.compactMap { $0(firsts[index]) }.joined(separator: " · ")
            return title.isEmpty ? "Set \(index + 1)" : title
        }
    }

    // MARK: - Figures

    /// Every measurement's id, the newest run's order first, then any that only older runs have.
    private static func measurementIDs(_ ordered: [BenchmarkRun]) -> [String] {
        unique(ordered.reversed().flatMap { $0.measurements.map(\.id) })
    }

    /// A figure's points; `comparable` holds the runs the baseline can be compared with.
    private static func figure(_ id: String, runs: [BenchmarkRun], lineOf: [String: Int], baseline: BenchmarkRun?,
                               comparable: Set<String>) -> Figure? {
        let reference = baseline?.measurement(id)
        var points: [Point] = []
        for (sequence, run) in runs.enumerated() {
            guard let measurement = run.measurement(id) else { continue }
            let isBaseline = run.id == baseline?.id
            let change = reference.flatMap { reference in
                isBaseline || comparable.contains(run.id) ? BenchmarkChange(baseline: reference, compared: measurement) : nil
            }
            points.append(Point(runID: run.id, line: lineOf[run.id] ?? 0, sequence: sequence, date: run.date, value: measurement.value,
                                low: measurement.low, high: measurement.high, repeats: measurement.repeats, caveat: measurement.caveat,
                                fromBaseline: change, isBaseline: isBaseline))
        }
        guard let newest = runs.last(where: { $0.measurement(id) != nil })?.measurement(id) else { return nil }
        let largest = points.map { $0.high ?? $0.value }.max() ?? 0
        let scale = newest.unit.scale(largest)
        let domain = domain(points)
        let ticks = ticks(domain, divisor: scale.divisor)
        return Figure(id: id, title: newest.title, unit: newest.unit, points: points, scaleUnit: scale.unit, divisor: scale.divisor,
                      domain: domain, ticks: ticks.values, tickDecimals: ticks.decimals)
    }

    /// The most ticks an axis gets.
    static let maximumTicks = 4

    /// As many round values inside `domain` as fit `maximumTicks`, read in
    /// `divisor`'s scale: steps of 1, 2 or 5 times a power of ten, so a label
    /// never rounds to a figure its tick isn't at. Returned in the figures'
    /// own units, with the decimals their labels need.
    static func ticks(_ domain: ClosedRange<Double>, divisor: Double) -> (values: [Double], decimals: Int) {
        let low = domain.lowerBound / divisor
        let high = domain.upperBound / divisor
        guard high > low, low.isFinite, high.isFinite else { return ([], 0) }
        let base = pow(10, floor(log10((high - low) / Double(maximumTicks))))
        for step in [1, 2, 5, 10, 20, 50].map({ $0 * base }) {
            let first = Int((low / step - 1e-9).rounded(.up))
            let last = Int((high / step + 1e-9).rounded(.down))
            guard last - first + 1 <= maximumTicks else { continue }
            let decimals = max(0, -Int(floor(log10(step) + 1e-9)))
            return ((first...max(first, last)).filter { $0 <= last }.map { Double($0) * step * divisor }, decimals)
        }
        return ([], 0)
    }

    /// From the lowest repeat to the highest, a tenth of the range more each
    /// side, at least `minimumSpan` of the middle wide, and never below zero.
    static func domain(_ points: [Point]) -> ClosedRange<Double> {
        let lows = points.map { $0.low ?? $0.value }.filter(\.isFinite)
        let highs = points.map { $0.high ?? $0.value }.filter(\.isFinite)
        guard let low = lows.min(), let high = highs.max() else { return 0...1 }
        let middle = (low + high) / 2
        let span = max(high - low, abs(middle) * minimumSpan, .ulpOfOne)
        let padding = (span - (high - low)) / 2 + span / 10
        let lower = max(low - padding, 0)
        return lower...max(high + padding, lower + span)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public extension BenchmarkComparison {
    /// The newest run and the newest earlier one it can be compared with,
    /// the earlier first: the pair a "compare" link picks. Nil when no
    /// earlier run can be compared with the newest.
    static func latestPair(_ runs: [BenchmarkRun]) -> (earlier: BenchmarkRun, later: BenchmarkRun)? {
        let newestFirst = runs.sorted { $0.date > $1.date }
        guard let newest = newestFirst.first,
              let earlier = newestFirst.dropFirst().first(where: { refusal($0, newest) == nil }) else { return nil }
        return (earlier, newest)
    }
}
