import Foundation

/// Where the Mac drew its power when a test started, as IOPowerSources says.
public enum BenchmarkPowerSource: String, Sendable, Codable {
    /// Mains power: a laptop's power adapter, or a desktop's own supply.
    case ac
    case battery
    /// An uninterruptible power supply that reports itself as the source.
    case ups

    /// "on battery", "on the power adapter" (a Mac with a battery), "on AC power".
    public func phrase(hasBattery: Bool?) -> String {
        switch self {
        case .ac: hasBattery == true ? "on the power adapter" : "on AC power"
        case .battery: "on battery"
        case .ups: "on a UPS"
        }
    }
}

/// How busy the whole CPU was in the few seconds before a test started.
public struct BenchmarkCPULoad: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        /// The app's own sampler, over its last few updates.
        case sampler
        /// The CPU's tick counters read twice just for the test (`otm`, or a paused app).
        case probe
    }

    /// Share of the whole CPU busy, 0...1.
    public var busy: Double
    /// How long it was measured over.
    public var seconds: Double
    public var source: Source

    public init(busy: Double, seconds: Double, source: Source) {
        self.busy = busy
        self.seconds = seconds
        self.source = source
    }

    /// The mean of a sampler's latest whole-CPU loads (0...1, oldest first,
    /// one every `step` seconds) over about `seconds`. The oldest value held
    /// is never used: a sampler's first reading covers the time since boot.
    /// Nil with fewer than two values.
    public static func recent(_ values: [Double], step: Double, seconds: Double) -> Self? {
        guard step > 0, step.isFinite, values.count >= 2 else { return nil }
        let count = min(values.count - 1, max(1, Int((seconds / step).rounded())))
        let busy = values.suffix(count).reduce(0, +) / Double(count)
        guard busy.isFinite else { return nil }
        return Self(busy: min(max(busy, 0), 1), seconds: Double(count) * step, source: .sampler)
    }
}

/// What the Mac was and was doing when a test ran: the system and app, the
/// hardware, power, heat, how busy the CPU was just before and how much
/// memory was free. Saved with each new run of every test as an optional,
/// separately versioned block (`context` in the history entry), so older
/// runs load without it ("context not recorded") and their files are never
/// rewritten. Every field is optional and read leniently: one that's missing,
/// unreadable or from a later version is nil, never a lost run.
public struct BenchmarkContext: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    /// What a run without one shows.
    public static let notRecorded = "Context not recorded"

    public var version: Int
    /// "macOS 27.2 (27C61)".
    public var osVersion: String?
    /// "OpenTaskManager 0.1.0", "otm 0.1.0".
    public var appVersion: String?
    /// A release (optimised) build of the app.
    public var optimized: Bool?
    /// "Mac17,8".
    public var model: String?
    /// "Apple M5 Pro".
    public var chip: String?
    public var power: BenchmarkPowerSource?
    /// Whether the Mac has a battery at all, so mains power reads right.
    public var hasBattery: Bool?
    public var lowPowerMode: Bool?
    /// `ProcessInfo.thermalState` as the run started and as it ended.
    public var thermalAtStart: ThermalState?
    public var thermalAtEnd: ThermalState?
    public var cpuLoad: BenchmarkCPULoad?
    /// Free memory plus cached files, as the Memory page counts what's available.
    public var availableMemoryBytes: UInt64?
    public var physicalMemoryBytes: UInt64?

    public init(version: Int = Self.currentVersion, osVersion: String? = nil, appVersion: String? = nil, optimized: Bool? = nil,
                model: String? = nil, chip: String? = nil, power: BenchmarkPowerSource? = nil, hasBattery: Bool? = nil,
                lowPowerMode: Bool? = nil, thermalAtStart: ThermalState? = nil, thermalAtEnd: ThermalState? = nil,
                cpuLoad: BenchmarkCPULoad? = nil, availableMemoryBytes: UInt64? = nil, physicalMemoryBytes: UInt64? = nil) {
        self.version = version
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.optimized = optimized
        self.model = model
        self.chip = chip
        self.power = power
        self.hasBattery = hasBattery
        self.lowPowerMode = lowPowerMode
        self.thermalAtStart = thermalAtStart
        self.thermalAtEnd = thermalAtEnd
        self.cpuLoad = cpuLoad
        self.availableMemoryBytes = availableMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// Field by field, each that can't be read left nil, so a damaged field
    /// or a later version's new value costs that field, not the run. A
    /// context that isn't an object at all reads as empty (`isEmpty`), which
    /// the run treats as not recorded.
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(version: 0)
            return
        }
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            try? container.decodeIfPresent(T.self, forKey: key)
        }
        self.init(version: field(.version) ?? 1, osVersion: field(.osVersion), appVersion: field(.appVersion),
                  optimized: field(.optimized), model: field(.model), chip: field(.chip), power: field(.power),
                  hasBattery: field(.hasBattery), lowPowerMode: field(.lowPowerMode), thermalAtStart: field(.thermalAtStart),
                  thermalAtEnd: field(.thermalAtEnd), cpuLoad: field(.cpuLoad), availableMemoryBytes: field(.availableMemoryBytes),
                  physicalMemoryBytes: field(.physicalMemoryBytes))
    }

    /// Whether nothing was read: a context that couldn't be decoded.
    public var isEmpty: Bool {
        self == Self(version: version)
    }

    /// The worse of the thermal states at the start and the end.
    public var worstThermal: ThermalState? {
        [thermalAtStart, thermalAtEnd].compactMap(\.self).max { $0.severity < $1.severity }
    }

    // MARK: - In words

    /// "on the power adapter".
    public var powerText: String? {
        power?.phrase(hasBattery: hasBattery)
    }

    /// "thermal nominal", "thermal nominal, then fair".
    public var thermalText: String? {
        switch (thermalAtStart, thermalAtEnd) {
        case let (start?, end?): start == end ? "thermal \(start.rawValue)" : "thermal \(start.rawValue), then \(end.rawValue)"
        case let (start?, nil): "thermal \(start.rawValue) at the start"
        case let (nil, end?): "thermal \(end.rawValue) at the end"
        case (nil, nil): nil
        }
    }

    /// "CPU 4% busy before".
    public var loadText: String? {
        cpuLoad.map { "CPU \(Format.percent($0.busy)) busy before" }
    }

    /// "21.3 GB memory available".
    public var memoryText: String? {
        availableMemoryBytes.map { "\(Format.bytes($0)) memory available" }
    }

    /// How the Mac stood as the run started, in a line: "on the power adapter ·
    /// Low Power Mode on · thermal nominal, then fair · CPU 4% busy before · 21.3 GB memory available".
    public var conditionsLine: String {
        [powerText, lowPowerMode == true ? "Low Power Mode on" : nil, thermalText, loadText, memoryText]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// What ran and on what: "macOS 27.2 (27C61) · OpenTaskManager 0.1.0, release build · Mac17,8 · Apple M5 Pro".
    public var provenanceLine: String {
        let app = appVersion.map { app in optimized.map { "\(app), \($0 ? "release" : "debug") build" } ?? app }
        return [osVersion, app, model, chip].compactMap(\.self).joined(separator: " · ")
    }

    /// Both lines, for a run's tooltip.
    public var summary: String {
        [conditionsLine, provenanceLine].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Two runs' contexts side by side

/// Something that differed between two runs' starts, or that may have held
/// one back: power, heat, load, memory, the Mac or the app. A warning beside
/// a comparison, never a reason to refuse it: only a different workload
/// version or kind of build refuses (`BenchmarkRefusal`).
public struct BenchmarkContextWarning: Sendable, Codable, Equatable, Identifiable {
    public enum Topic: String, Sendable, Codable {
        case notRecorded, power, thermal, cpuLoad, memory, hardware, build
    }

    public var topic: Topic
    public var text: String

    public var id: String { topic.rawValue }

    public init(topic: Topic, text: String) {
        self.topic = topic
        self.text = text
    }
}

public extension BenchmarkContext {
    /// A run that started with this much of the CPU busy may have been held back.
    static let busyCPU = 0.20
    /// Two runs whose CPU busy figures differ by less than this started alike.
    static let busyDifference = 0.10
    /// Memory available differs enough to mention when the smaller is under
    /// this share of the larger, and at least `memoryDifference` smaller.
    static let memoryShare = 0.5
    static let memoryDifference: UInt64 = 1 << 30

    /// What differed between `earlier`'s start and `later`'s, or held either
    /// back, in plain words, the earlier run first. Runs that record their
    /// build or their Mac themselves (the CPU and GPU benchmarks) are refused
    /// over those already, so `runsRecordBuild` and `runsRecordMachine` leave
    /// them out here. Nothing when neither run recorded its context.
    static func warnings(earlier: Self?, later: Self?, runsRecordBuild: Bool = false,
                         runsRecordMachine: Bool = false) -> [BenchmarkContextWarning] {
        switch (earlier, later) {
        case (nil, nil):
            return []
        case (nil, _?), (_?, nil):
            let missing = earlier == nil ? "earlier" : "later"
            let known = earlier == nil ? "later" : "earlier"
            return [BenchmarkContextWarning(topic: .notRecorded, text: "The \(missing) run didn't record its context (power, heat and "
                    + "load at the start), so only the \(known) run's is known.")]
        case let (one?, other?):
            return [
                powerWarning(one, other), thermalWarning(one, other), loadWarning(one, other), memoryWarning(one, other),
                runsRecordMachine ? nil : hardwareWarning(one, other), runsRecordBuild ? nil : buildWarning(one, other),
            ].compactMap(\.self)
        }
    }

    private static func powerWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        guard let first = one.power, let second = other.power, first != second else { return nil }
        let battery = one.hasBattery ?? other.hasBattery
        return BenchmarkContextWarning(topic: .power, text: "The earlier run was \(first.phrase(hasBattery: battery)), "
            + "the later \(second.phrase(hasBattery: battery)).")
    }

    private static func thermalWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        guard let first = one.thermalAtStart, let second = other.thermalAtStart else { return nil }
        if first != second {
            let (hotter, cooler) = first.severity > second.severity ? ("earlier", "later") : ("later", "earlier")
            let (high, low) = first.severity > second.severity ? (first, second) : (second, first)
            return BenchmarkContextWarning(topic: .thermal, text: "The \(hotter) run started at thermal state \(high.rawValue), "
                + "the \(cooler) at \(low.rawValue).")
        }
        guard first != .nominal else { return nil }
        return BenchmarkContextWarning(topic: .thermal, text: "Both runs started at thermal state \(first.rawValue).")
    }

    private static func loadWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        guard let first = one.cpuLoad?.busy, let second = other.cpuLoad?.busy, max(first, second) >= busyCPU else { return nil }
        if abs(first - second) >= busyDifference {
            let (busier, calmer) = first > second ? ("earlier", "later") : ("later", "earlier")
            return BenchmarkContextWarning(topic: .cpuLoad, text: "The \(busier) run started with \(Format.percent(max(first, second))) "
                + "of the CPU busy, the \(calmer) with \(Format.percent(min(first, second))).")
        }
        return BenchmarkContextWarning(topic: .cpuLoad, text: "Both runs started with the CPU busy: \(Format.percent(first)) "
            + "and \(Format.percent(second)).")
    }

    private static func memoryWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        guard let first = one.availableMemoryBytes, let second = other.availableMemoryBytes else { return nil }
        let (low, high) = (min(first, second), max(first, second))
        guard high > 0, Double(low) < Double(high) * memoryShare, high - low >= memoryDifference else { return nil }
        let (scarcer, roomier) = first < second ? ("earlier", "later") : ("later", "earlier")
        return BenchmarkContextWarning(topic: .memory, text: "The \(scarcer) run started with \(Format.bytes(low)) of memory "
            + "available, the \(roomier) with \(Format.bytes(high)).")
    }

    private static func hardwareWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        func name(_ context: Self) -> String? {
            switch (context.model, context.chip) {
            case let (model?, chip?): "\(model) (\(chip))"
            case let (model, chip): model ?? chip
            }
        }
        let differs = (one.model != nil && other.model != nil && one.model != other.model)
            || (one.chip != nil && other.chip != nil && one.chip != other.chip)
        guard differs, let first = name(one), let second = name(other) else { return nil }
        return BenchmarkContextWarning(topic: .hardware, text: "The runs were on different Macs: \(first), then \(second).")
    }

    private static func buildWarning(_ one: Self, _ other: Self) -> BenchmarkContextWarning? {
        if let first = one.optimized, let second = other.optimized, first != second {
            return BenchmarkContextWarning(topic: .build, text: "The earlier run came from a \(first ? "release" : "debug") build of the "
                + "app, the later from a \(second ? "release" : "debug") build.")
        }
        if let first = one.appVersion, let second = other.appVersion, first != second {
            return BenchmarkContextWarning(topic: .build, text: "The app changed between the runs: \(first), then \(second).")
        }
        return nil
    }
}
