import Foundation

/// Why two runs can't be compared, said plainly. Only runs of the same test,
/// workloads, settings, kind of build, Mac and target measure the same thing.
public enum BenchmarkRefusal: Sendable, Equatable {
    case sameRun
    case differentTests(BenchmarkKind, BenchmarkKind)
    case differentWorkloadVersions(Int, Int)
    /// One run from a debug build and one from a release build; `baselineOptimized` says which is which.
    case differentBuilds(baselineOptimized: Bool)
    case differentMachines(String, String)
    case differentTargets(BenchmarkKind, String, String)
    case differentSettings(name: String, baseline: String, compared: String)

    public var reason: String {
        switch self {
        case .sameRun:
            return "That's the same run twice. Pick two different runs."
        case let .differentTests(baseline, compared):
            return "These are different tests (\(baseline.title) and \(compared.title)), so their figures don't measure the same thing."
        case let .differentWorkloadVersions(baseline, compared):
            return "The runs used different versions of the workloads (v\(baseline) and v\(compared)), so they didn't do the same work. "
                + "Compare two runs of the same version."
        case let .differentBuilds(baselineOptimized):
            let order = baselineOptimized ? "The earlier run is from a release build and the later one from a debug build"
                : "The earlier run is from a debug build and the later one from a release build"
            return "\(order) of the app. Runs from different kinds of build aren't compared, since a debug build runs the app's "
                + "own code many times slower: pick two release runs, or two debug runs."
        case let .differentMachines(baseline, compared):
            return "The runs come from different hardware (\(baseline), and \(compared)), so a difference says nothing about change."
        case let .differentTargets(kind, baseline, compared):
            let what = kind == .network ? "interfaces" : kind == .disk ? "volumes" : "targets"
            return "The runs tested different \(what) (\(baseline) and \(compared)). Compare two runs on the same one."
        case let .differentSettings(name, baseline, compared):
            return "The runs were set up differently: \(name.lowercased()) \(baseline) in one and \(compared) in the other. "
                + "Compare two runs with the same settings."
        }
    }
}

/// How one figure moved between two runs.
public struct BenchmarkChange: Sendable, Codable, Equatable, Identifiable {
    public enum Verdict: String, Sendable, Codable {
        /// Moved the good way, past both runs' spread.
        case better
        /// Moved the bad way, past both runs' spread.
        case worse
        /// The two runs' ranges of repeats overlap: what moved could be noise.
        case withinSpread
        /// Measured once in a run, so there's no spread to tell noise from change.
        case measuredOnce
        case unchanged
    }

    public var id: String
    public var title: String
    public var unit: BenchmarkUnit
    public var baseline: Double
    public var compared: Double
    /// (compared − baseline) / baseline; nil when the baseline is zero.
    public var change: Double?
    /// Each run's slowest-to-fastest spread as a share of its figure.
    public var baselineSpread: Double?
    public var comparedSpread: Double?
    public var verdict: Verdict

    public init(baseline: BenchmarkMeasurement, compared: BenchmarkMeasurement) {
        id = baseline.id
        title = baseline.title
        unit = baseline.unit
        self.baseline = baseline.value
        self.compared = compared.value
        change = Self.change(from: baseline.value, to: compared.value)
        baselineSpread = baseline.spread
        comparedSpread = compared.spread
        verdict = Self.verdict(baseline: baseline, compared: compared)
    }

    /// (to − from) / from, nil when `from` isn't a positive figure.
    public static func change(from baseline: Double, to compared: Double) -> Double? {
        guard baseline > 0, baseline.isFinite, compared.isFinite else { return nil }
        return (compared - baseline) / baseline
    }

    /// A change counts only when the two runs' ranges of repeats (slowest to
    /// fastest) don't overlap; otherwise one run's noise could explain it.
    public static func verdict(baseline: BenchmarkMeasurement, compared: BenchmarkMeasurement) -> Verdict {
        if compared.value == baseline.value { return .unchanged }
        guard let baseLow = baseline.low, let baseHigh = baseline.high, let low = compared.low, let high = compared.high else {
            return .measuredOnce
        }
        if baseLow <= high, low <= baseHigh { return .withinSpread }
        return (compared.value > baseline.value) == baseline.unit.higherIsBetter ? .better : .worse
    }
}

/// Two compatible runs of a test side by side: each figure's change, with
/// both runs' spread, and what else differed between them.
public struct BenchmarkComparison: Sendable, Codable, Equatable {
    /// The earlier run's id, and the later one's.
    public var baseline: String
    public var compared: String
    public var changes: [BenchmarkChange]
    /// What the figures can't show: other macOS or app versions, heat, a
    /// cache that wasn't bypassed, a test that measures once.
    public var caveats: [String]

    public enum Outcome: Sendable, Equatable {
        case compared(BenchmarkComparison)
        case refused(BenchmarkRefusal)
    }

    /// Compares two runs, the earlier as the baseline whichever order they come in.
    public static func compare(_ first: BenchmarkRun, _ second: BenchmarkRun) -> Outcome {
        let (baseline, compared) = first.date <= second.date ? (first, second) : (second, first)
        if let refusal = refusal(baseline, compared) { return .refused(refusal) }
        let changes = baseline.measurements.compactMap { measurement in
            compared.measurement(measurement.id).map { BenchmarkChange(baseline: measurement, compared: $0) }
        }
        return .compared(BenchmarkComparison(baseline: baseline.id, compared: compared.id, changes: changes,
                                             caveats: caveats(baseline, compared, changes: changes)))
    }

    /// Why `baseline` and `compared` can't be compared, or nil when they can.
    public static func refusal(_ baseline: BenchmarkRun, _ compared: BenchmarkRun) -> BenchmarkRefusal? {
        if baseline.id == compared.id { return .sameRun }
        if baseline.kind != compared.kind { return .differentTests(baseline.kind, compared.kind) }
        if baseline.workloadVersion != compared.workloadVersion {
            return .differentWorkloadVersions(baseline.workloadVersion, compared.workloadVersion)
        }
        if let one = baseline.build, let other = compared.build, one.optimized != other.optimized {
            return .differentBuilds(baselineOptimized: one.optimized)
        }
        if let one = baseline.machine, let other = compared.machine, one.key != other.key {
            return .differentMachines(one.name, other.name)
        }
        if let one = baseline.target, let other = compared.target, one.key != other.key {
            return .differentTargets(baseline.kind, one.name, other.name)
        }
        for setting in baseline.settings {
            let other = compared.settings.first { $0.name == setting.name }
            if other?.value != setting.value {
                return .differentSettings(name: setting.name, baseline: setting.value, compared: other?.value ?? "none")
            }
        }
        if let extra = compared.settings.first(where: { setting in !baseline.settings.contains { $0.name == setting.name } }) {
            return .differentSettings(name: extra.name, baseline: "none", compared: extra.value)
        }
        return nil
    }

    private static func caveats(_ baseline: BenchmarkRun, _ compared: BenchmarkRun, changes: [BenchmarkChange]) -> [String] {
        var caveats: [String] = []
        if !baseline.kind.measuresThisMac {
            var line = "Internet figures depend on the connection, the server and other traffic at the time, not on this Mac"
            if let one = baseline.target?.detail, let other = compared.target?.detail, one != other {
                line += "; these runs reached different servers (\(one), then \(other))"
            }
            caveats.append(line + ".")
        }
        if changes.contains(where: { $0.verdict == .measuredOnce }) {
            caveats.append("This test measures each figure once, so there's no spread to tell noise from change: "
                + "repeat the run before trusting a small difference.")
        }
        if baseline.build?.optimized == false, compared.build?.optimized == false {
            caveats.append("Both runs are from a debug build, which runs the app's own code many times slower than a release build: "
                + "these figures compare only with each other.")
        }
        if let one = baseline.osVersion, let other = compared.osVersion, one != other {
            caveats.append("The system changed between the runs: \(one), then \(other).")
        }
        if let one = baseline.build?.app, let other = compared.build?.app, one != other {
            caveats.append("The app changed between the runs: \(one), then \(other).")
        }
        if !baseline.conditions.isEmpty {
            caveats.append("Earlier run: " + baseline.conditions.joined(separator: "; ") + ".")
        }
        if !compared.conditions.isEmpty {
            caveats.append("Later run: " + compared.conditions.joined(separator: "; ") + ".")
        }
        return caveats
    }
}
