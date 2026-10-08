import Foundation

/// What a sustained run's windows add up to: the first window's speed, the
/// level it settled at (the median of the last third of the windows), the
/// one as a share of the other in plain words, and what macOS reported
/// about heat along the way. It says what changed, never why: a run can
/// slow for heat, for other work, or for power settings, and only the
/// thermal state macOS reported is known.
public struct CPUSustainedSummary: Sendable, Equatable {
    /// A thermal state macOS reported, and from when.
    public struct ThermalStep: Sendable, Equatable {
        public var state: ThermalState
        /// Seconds from the end of the warm-up; 0 for the state at the start.
        public var at: Double
    }

    /// The first window's throughput.
    public var first: Double
    /// The median of the last third's windows' throughput.
    public var sustained: Double
    /// The slowest and fastest windows of the last third.
    public var sustainedLow: Double
    public var sustainedHigh: Double
    /// How many windows the last third holds.
    public var sustainedWindows: Int
    public var windowCount: Int
    /// The slowest and fastest windows of the whole run.
    public var lowest: Double
    public var highest: Double
    /// The thermal state at the start, then each change, in order.
    public var thermalSteps: [ThermalStep]

    /// Nil with no windows.
    public init?(windows: [CPUSustainedWindow], thermalAtStart: ThermalState? = nil) {
        guard let firstWindow = windows.first else { return nil }
        let throughputs = windows.map(\.throughput)
        let tail = Array(throughputs.suffix(Self.lastThird(of: throughputs.count)))
        first = firstWindow.throughput
        sustained = Self.median(tail)
        sustainedLow = tail.min() ?? 0
        sustainedHigh = tail.max() ?? 0
        sustainedWindows = tail.count
        windowCount = windows.count
        lowest = throughputs.min() ?? 0
        highest = throughputs.max() ?? 0
        var steps = [ThermalStep(state: thermalAtStart ?? firstWindow.thermalState, at: 0)]
        for window in windows where window.thermalState != steps[steps.count - 1].state {
            steps.append(ThermalStep(state: window.thermalState, at: window.end))
        }
        thermalSteps = steps
    }

    /// The windows the sustained level is the median of: the last third,
    /// rounded up, and at least one.
    public static func lastThird(of count: Int) -> Int {
        max(1, (count + 2) / 3)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The sustained level as a share of the first window's; nil when the
    /// first window measured nothing.
    public var ratio: Double? {
        guard first > 0, first.isFinite, sustained.isFinite else { return nil }
        return sustained / first
    }

    /// The ratio as a whole percentage: 97 for 0.968.
    public var heldPercent: Int? {
        ratio.map { Int(($0 * 100).rounded()) }
    }

    /// "Held 97% of its starting speed", "Held its starting speed",
    /// "Ended 3% faster than it started".
    public var heldText: String {
        guard let percent = heldPercent else { return "Nothing was measured in the first window" }
        if percent == 100 { return "Held its starting speed" }
        if percent > 100 { return "Ended \(percent - 100)% faster than it started" }
        return "Held \(percent)% of its starting speed"
    }

    /// What changed, with figures: "The first 10 s window ran at 172 MFLOP/s;
    /// the last 4 settled at a median of 166 MFLOP/s (163 to 168 MFLOP/s)."
    public func changeText(format: (Double) -> String, windowSeconds: Double) -> String {
        let window = "The first \(Format.timeSpan(windowSeconds)) window ran at \(format(first))"
        guard windowCount > 1 else { return window + ", the only window of the run." }
        let tail = sustainedWindows == 1 ? "the last window ran at \(format(sustained))"
            : "the last \(sustainedWindows) settled at a median of \(format(sustained))"
            + (sustainedLow < sustainedHigh ? " (\(format(sustainedLow)) to \(format(sustainedHigh)))" : "")
        return "\(window); \(tail)."
    }

    /// What macOS reported about heat, from the start: "macOS reported
    /// thermal state nominal throughout." or "macOS reported thermal state
    /// nominal at the start, fair from 0:50 and serious from 1:40."
    public var thermalText: String {
        guard let start = thermalSteps.first else { return "" }
        guard thermalSteps.count > 1 else { return "macOS reported thermal state \(start.state.rawValue) throughout." }
        let changes = thermalSteps.dropFirst().map { "\($0.state.rawValue) from \(Self.clock($0.at))" }
        let list = changes.count == 1 ? changes[0] : changes.dropLast().joined(separator: ", ") + " and " + (changes.last ?? "")
        return "macOS reported thermal state \(start.state.rawValue) at the start, \(list)."
    }

    /// The worst state macOS reported.
    public var worstThermal: ThermalState {
        thermalSteps.map(\.state).max { $0.severity < $1.severity } ?? .nominal
    }

    /// "1:40": minutes and seconds into the timed run.
    public static func clock(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded())
        return "\(whole / 60):" + (whole % 60 < 10 ? "0" : "") + "\(whole % 60)"
    }
}

/// A sustained run's windows as a saved run carries them, for its chart and summary.
public struct BenchmarkSustainedTrace: Sendable, Codable, Equatable {
    public var unit: BenchmarkUnit
    public var windowSeconds: Double
    public var thermalAtStart: ThermalState
    public var windows: [CPUSustainedWindow]

    public init(unit: BenchmarkUnit, windowSeconds: Double, thermalAtStart: ThermalState, windows: [CPUSustainedWindow]) {
        self.unit = unit
        self.windowSeconds = windowSeconds
        self.thermalAtStart = thermalAtStart
        self.windows = windows
    }

    public var summary: CPUSustainedSummary? {
        CPUSustainedSummary(windows: windows, thermalAtStart: thermalAtStart)
    }

    /// "Held 97% of its starting speed. The first 10 s window ran at …; …. macOS reported …"
    public var narrative: String? {
        guard let summary else { return nil }
        return "\(summary.heldText). \(summary.changeText(format: unit.format, windowSeconds: windowSeconds)) \(summary.thermalText)"
    }

    /// The chart's axes: throughput from zero, so a level line reads as
    /// one, and time in half minutes, or minutes over three.
    public var axis: SustainedChartAxis {
        SustainedChartAxis(unit: unit, highest: windows.map(\.throughput).filter(\.isFinite).max() ?? 0,
                           seconds: windows.last?.end ?? windowSeconds)
    }
}

/// A sustained run's chart axes: throughput from zero up to a round figure
/// over the fastest window, and the run's time in clock ticks.
public struct SustainedChartAxis: Sendable, Equatable {
    /// The top of the throughput axis, in the figures' own units.
    public var top: Double
    /// Throughput ticks, in the figures' own units, from zero.
    public var ticks: [Double]
    /// "GFLOP/s", and what to divide by for it.
    public var unit: String
    public var divisor: Double
    public var decimals: Int
    /// The end of the time axis: the last window's end.
    public var seconds: Double
    /// "0:00", "0:30", … in seconds from the end of the warm-up.
    public var timeTicks: [Double]

    public init(unit: BenchmarkUnit, highest: Double, seconds: Double) {
        let scale = unit.scale(highest)
        let top = highest > 0 ? GraphMath.niceCeiling(highest * 1.05 / scale.divisor) * scale.divisor : 1
        let ticks = BenchmarkTrend.ticks(0...top, divisor: scale.divisor)
        self.top = top
        self.ticks = ticks.values
        self.unit = scale.unit
        divisor = scale.divisor
        decimals = ticks.decimals
        self.seconds = max(seconds, 1)
        let step: Double = seconds > 180 ? 60 : 30
        timeTicks = (0...Int((self.seconds / step + 1e-9).rounded(.down))).map { Double($0) * step }
    }

    /// A tick's label, without its unit: "150".
    public func label(_ value: Double) -> String {
        Format.fixed(value / divisor, decimals)
    }
}

public extension BenchmarkRun {
    init(_ result: CPUSustainedResult) {
        let configuration = result.configuration
        let unit: BenchmarkUnit = configuration.workload.countsBytes ? .bytesPerSecond : .flopsPerSecond
        var measurements: [BenchmarkMeasurement] = []
        if let summary = result.summary, let first = result.windows.first {
            measurements = [
                BenchmarkMeasurement(id: "firstWindow", name: "First window", value: summary.first, unit: unit,
                                     low: first.slices.min(), high: first.slices.max(),
                                     repeats: first.slices.isEmpty ? nil : first.slices.count),
                BenchmarkMeasurement(id: "sustained", name: "Sustained", variant: "median of the last \(summary.sustainedWindows)",
                                     value: summary.sustained, unit: unit, low: summary.sustainedLow, high: summary.sustainedHigh,
                                     repeats: summary.sustainedWindows),
            ]
        }
        let kernels = configuration.kernels
        let workloadSize = configuration.workload == .floatingPoint ? "\(kernels.matrixSize) × \(kernels.matrixSize) matrices"
            : configuration.workload == .integer ? "\(Format.wholeBytes(UInt64(kernels.hashBytes))) buffer"
            : "\(Format.wholeBytes(UInt64(kernels.memoryBytes))) buffer"
        let machine = result.machine
        self.init(
            id: Self.id(.sustained, result.date), kind: .sustained, date: result.date, workloadVersion: result.suiteVersion,
            settings: [
                BenchmarkSetting(name: "Workload", value: "\(configuration.workload.title), \(workloadSize)"),
                BenchmarkSetting(name: "Workers", value: "\(result.workers)"),
                BenchmarkSetting(name: "Duration", value: configuration.durationText),
                BenchmarkSetting(name: "Windows", value: "\(configuration.windowCount) × \(Format.timeSpan(configuration.windowSeconds)), "
                    + "\(configuration.slicesPerWindow) slices each"),
                BenchmarkSetting(name: "Warm-up", value: "\(Format.fixed(configuration.warmUpSeconds, 1)) s"),
                BenchmarkSetting(name: "Seed", value: String(kernels.seed, radix: 16, uppercase: true)),
            ],
            build: BenchmarkBuild(app: result.appVersion, optimized: result.optimized),
            machine: BenchmarkMachine(key: machine.key, name: [machine.chip, machine.model].compactMap { $0 }.joined(separator: " · ")),
            target: nil, osVersion: result.osVersion,
            conditions: Self.conditions(thermal: result.worstThermalState, lowPower: result.lowPowerMode),
            measurements: measurements, context: result.context,
            sustained: BenchmarkSustainedTrace(unit: unit, windowSeconds: configuration.windowSeconds,
                                               thermalAtStart: result.thermalStateAtStart, windows: result.windows)
        )
    }
}
