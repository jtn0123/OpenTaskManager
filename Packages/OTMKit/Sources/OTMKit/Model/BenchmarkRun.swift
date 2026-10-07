import Foundation

/// The four tests the Benchmarks workspace gathers. The CPU, GPU and disk
/// tests measure this Mac; the Internet test measures the connection.
public enum BenchmarkKind: String, Sendable, Codable, CaseIterable {
    case cpu, gpu, disk, network

    public var title: String {
        switch self {
        case .cpu: "CPU benchmark"
        case .gpu: "GPU benchmark"
        case .disk: "Disk speed"
        case .network: "Internet quality"
        }
    }

    /// Whether the figures are this Mac's own. The Internet test's depend on
    /// the connection, the server and other traffic at the time.
    public var measuresThisMac: Bool { self != .network }

    /// What a run's version numbers: the benchmarks' workloads, or the
    /// disk and Internet tests' method. "workloads v2", "test v1".
    public var versionName: String {
        switch self {
        case .cpu, .gpu: "workloads"
        case .disk, .network: "test"
        }
    }
}

/// What a figure counts. Rates are per second, decimal, as benchmarks quote
/// them; disk speeds are in MB/s, as the disk test shows them.
public enum BenchmarkUnit: String, Sendable, Codable {
    case bytesPerSecond = "B/s"
    case flopsPerSecond = "FLOP/s"
    case pixelsPerSecond = "pixel/s"
    case megabytesPerSecond = "MB/s"
    case bitsPerSecond = "bit/s"
    case operationsPerSecond = "IOPS"
    /// Round trips a minute on a loaded connection.
    case roundTripsPerMinute = "RPM"
    case milliseconds = "ms"

    /// Whether a larger figure is the better one: every rate, but not a delay.
    public var higherIsBetter: Bool { self != .milliseconds }

    /// The unit for figures up to `largest`, and what to divide them by:
    /// ("GB/s", 1e9) for 12.4e9 B/s. Disk speeds, IOPS, RPM and milliseconds keep theirs.
    public func scale(_ largest: Double) -> (unit: String, divisor: Double) {
        let units: [String] = switch self {
        case .bytesPerSecond: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        case .flopsPerSecond: ["FLOP/s", "KFLOP/s", "MFLOP/s", "GFLOP/s", "TFLOP/s"]
        case .pixelsPerSecond: ["pixel/s", "Kpixel/s", "Mpixel/s", "Gpixel/s", "Tpixel/s"]
        case .bitsPerSecond: ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        case .megabytesPerSecond, .operationsPerSecond, .roundTripsPerMinute, .milliseconds: [rawValue]
        }
        var divisor = 1.0
        var index = 0
        while largest.isFinite, largest / divisor >= 1000, index < units.count - 1 {
            divisor *= 1000
            index += 1
        }
        return (units[index], divisor)
    }

    /// A figure in a column's scale, without its unit: "12.4", "2,950".
    public func number(_ value: Double, divisor: Double = 1) -> String {
        let scaled = value / divisor
        guard scaled.isFinite, scaled >= 0 else { return "—" }
        switch self {
        case .roundTripsPerMinute:
            return Int(scaled.rounded()).formatted()
        case .milliseconds:
            return Format.fixed(scaled, scaled >= 10 ? 0 : 1)
        case .megabytesPerSecond, .operationsPerSecond:
            if scaled >= 100 { return Int(scaled.rounded()).formatted() }
            return Format.fixed(scaled, scaled >= 10 || self == .operationsPerSecond ? 1 : 2)
        case .bitsPerSecond:
            return Format.fixed(scaled, divisor == 1 || scaled >= 100 ? 0 : 1)
        case .bytesPerSecond, .flopsPerSecond, .pixelsPerSecond:
            return Format.fixed(scaled, scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)
        }
    }

    /// A figure with its unit, scaled to itself: "12.4 GB/s", "2,950 MB/s", "312 RPM".
    public func format(_ value: Double) -> String {
        let scale = scale(value)
        return "\(number(value, divisor: scale.divisor)) \(scale.unit)"
    }
}

/// One figure of a run: a median of timed repeats, with the slowest and
/// fastest of them, or a single measurement.
public struct BenchmarkMeasurement: Sendable, Codable, Equatable, Identifiable {
    /// The same in every run of a test: "integer.single", "sequentialRead", "download".
    public var id: String
    /// "Integer", "Sequential read".
    public var name: String
    /// What sets it apart from another of the same name: "1 worker", "6 workers".
    public var variant: String?
    /// The median of the repeats, or the one measurement.
    public var value: Double
    public var unit: BenchmarkUnit
    /// The slowest and fastest repeats; nil when the test measures once.
    public var low: Double?
    public var high: Double?
    /// Timed repeats behind the figure; nil when the test measures once.
    public var repeats: Int?

    public init(id: String, name: String, variant: String? = nil, value: Double, unit: BenchmarkUnit, low: Double? = nil,
                high: Double? = nil, repeats: Int? = nil) {
        self.id = id
        self.name = name
        self.variant = variant
        self.value = value
        self.unit = unit
        self.low = low
        self.high = high
        self.repeats = repeats
    }

    /// From timed repeats: their median, slowest and fastest.
    init(id: String, name: String, variant: String? = nil, repeats values: [Double], unit: BenchmarkUnit) {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.isEmpty ? 0 : sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        self.init(id: id, name: name, variant: variant, value: median, unit: unit, low: sorted.first, high: sorted.last,
                  repeats: values.isEmpty ? nil : values.count)
    }

    /// "Integer, 6 workers".
    public var title: String {
        variant.map { "\(name), \($0)" } ?? name
    }

    /// How far apart the slowest and fastest repeats were, as a share of the
    /// figure; nil for a test that measures once. The cards show half of it as ±.
    public var spread: Double? {
        guard let low, let high, value > 0 else { return nil }
        return (high - low) / value
    }
}

/// A setting a run's figures depend on, beyond the workloads' version:
/// workers, buffer sizes, the test file, the tool's mode.
public struct BenchmarkSetting: Sendable, Codable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The app that ran a test, and whether it was optimised.
public struct BenchmarkBuild: Sendable, Codable, Equatable {
    /// "OpenTaskManager 0.1.0", "otm 0.1.0".
    public var app: String
    /// A release build. A debug build can run a benchmark far slower.
    public var optimized: Bool

    public init(app: String, optimized: Bool) {
        self.app = app
        self.optimized = optimized
    }

    /// "Release" or "Debug".
    public var title: String { optimized ? "Release" : "Debug" }
}

/// The Mac, or the Mac and its GPU, a run measured.
public struct BenchmarkMachine: Sendable, Codable, Equatable {
    /// What runs compare by: model, chip and cores; or model, GPU and cores.
    public var key: String
    /// "Apple M5 Pro · Mac17,8".
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// What a test ran against: a volume, or a network interface.
public struct BenchmarkTarget: Sendable, Codable, Equatable {
    /// What results are kept and compared by: the volume's UUID, the interface's BSD name.
    public var key: String
    /// "Macintosh HD", "en0".
    public var name: String
    /// Where exactly: the folder the test file went in, the server measured against.
    public var detail: String?

    public init(key: String, name: String, detail: String? = nil) {
        self.key = key
        self.name = name
        self.detail = detail
    }
}

/// One saved result of any of the four tests, in a shape they share: what
/// ran, in which build, on which Mac and against what, when, and its figures
/// with their units and spread. Made from each test's own history entry when
/// it's read; the history files themselves stay as they are.
public struct BenchmarkRun: Sendable, Codable, Equatable, Identifiable {
    /// The test and the time: "cpu-813075042220", milliseconds since 2001.
    public var id: String
    public var kind: BenchmarkKind
    public var date: Date
    /// The workloads' version (the CPU and GPU benchmarks' suite version, the
    /// disk and Internet tests' format version). Runs of different versions
    /// didn't do the same work.
    public var workloadVersion: Int
    public var settings: [BenchmarkSetting]
    /// Nil where the test doesn't record it (disk, Internet): their figures
    /// are the disk's and the connection's, timed outside the app's code.
    public var build: BenchmarkBuild?
    /// Nil where the test doesn't record it: those histories are this Mac's.
    public var machine: BenchmarkMachine?
    public var target: BenchmarkTarget?
    /// "macOS 27.2 (27C61)".
    public var osVersion: String?
    /// What may have held the figures back or flattered them: heat, Low
    /// Power Mode, a cache the test couldn't bypass.
    public var conditions: [String]
    public var measurements: [BenchmarkMeasurement]

    public init(id: String, kind: BenchmarkKind, date: Date, workloadVersion: Int, settings: [BenchmarkSetting], build: BenchmarkBuild?,
                machine: BenchmarkMachine?, target: BenchmarkTarget?, osVersion: String?, conditions: [String],
                measurements: [BenchmarkMeasurement]) {
        self.id = id
        self.kind = kind
        self.date = date
        self.workloadVersion = workloadVersion
        self.settings = settings
        self.build = build
        self.machine = machine
        self.target = target
        self.osVersion = osVersion
        self.conditions = conditions
        self.measurements = measurements
    }

    static func id(_ kind: BenchmarkKind, _ date: Date) -> String {
        "\(kind.rawValue)-\(Int64((date.timeIntervalSinceReferenceDate * 1000).rounded()))"
    }

    public func measurement(_ id: String) -> BenchmarkMeasurement? {
        measurements.first { $0.id == id }
    }

    /// The figures a one-line summary quotes: the CPU's on every worker,
    /// the Internet test's without its idle latency, the others' all.
    public var headline: [BenchmarkMeasurement] {
        switch kind {
        case .cpu: measurements.filter { $0.id.hasSuffix(".multi") }
        case .network: measurements.filter { $0.id != "idleLatency" }
        case .gpu, .disk: measurements
        }
    }

    /// "Integer 549 MB/s · Floating point 150 MFLOP/s · Memory 28.5 GB/s".
    public var headlineSummary: String {
        headline.map { "\($0.name) \($0.unit.format($0.value))" }.joined(separator: " · ")
    }

    /// The settings in a line: "6 workers · 256 KB hash buffer · …".
    public var settingsSummary: String {
        settings.map { "\($0.name) \($0.value)" }.joined(separator: " · ")
    }
}

// MARK: - From each test's history

public extension BenchmarkRun {
    init(_ result: CPUBenchmarkResult) {
        let configuration = result.configuration
        let workers = result.workloads.first?.multi.workers ?? result.machine.logicalCores
        var measurements: [BenchmarkMeasurement] = []
        for workload in result.workloads {
            let unit: BenchmarkUnit = workload.workload.countsBytes ? .bytesPerSecond : .flopsPerSecond
            measurements.append(BenchmarkMeasurement(id: "\(workload.workload.rawValue).single", name: workload.workload.title,
                                                     variant: "1 worker", repeats: workload.single.repeats, unit: unit))
            measurements.append(BenchmarkMeasurement(id: "\(workload.workload.rawValue).multi", name: workload.workload.title,
                                                     variant: "\(workload.multi.workers) workers", repeats: workload.multi.repeats,
                                                     unit: unit))
        }
        let machine = result.machine
        self.init(
            id: Self.id(.cpu, result.date), kind: .cpu, date: result.date, workloadVersion: result.suiteVersion,
            settings: [
                BenchmarkSetting(name: "Workers", value: "\(workers)"),
                BenchmarkSetting(name: "Integer buffer", value: Format.wholeBytes(UInt64(configuration.hashBytes))),
                BenchmarkSetting(name: "Matrix", value: "\(configuration.matrixSize) × \(configuration.matrixSize)"),
                BenchmarkSetting(name: "Memory buffer", value: "\(Format.wholeBytes(UInt64(configuration.memoryBytes))) in "
                    + "\(Format.wholeBytes(UInt64(configuration.memoryChunkBytes))) chunks"),
                Self.timing(warmUp: configuration.warmUpSeconds, repeats: configuration.repeats, seconds: configuration.repeatSeconds),
                BenchmarkSetting(name: "Seed", value: String(configuration.seed, radix: 16, uppercase: true)),
            ],
            build: BenchmarkBuild(app: result.appVersion, optimized: result.optimized),
            machine: BenchmarkMachine(key: machine.key, name: [machine.chip, machine.model].compactMap { $0 }.joined(separator: " · ")),
            target: nil, osVersion: result.osVersion,
            conditions: Self.conditions(thermal: result.worstThermalState, lowPower: result.lowPowerMode),
            measurements: measurements
        )
    }

    init(_ result: GPUBenchmarkResult) {
        let configuration = result.configuration
        let measurements = result.workloads.map { workload in
            let unit: BenchmarkUnit = switch workload.workload {
            case .compute: .flopsPerSecond
            case .memory: .bytesPerSecond
            case .fill: .pixelsPerSecond
            }
            return BenchmarkMeasurement(id: workload.workload.rawValue, name: workload.workload.title,
                                        repeats: workload.measurement.repeats, unit: unit)
        }
        var conditions = Self.conditions(thermal: result.worstThermalState, lowPower: result.lowPowerMode)
        let short = result.shortTimedWorkloads.map { $0.workload.title.lowercased() }
        if !short.isEmpty {
            conditions.append("GPU time looked short for \(short.joined(separator: " and ")), so "
                + "\(short.count == 1 ? "that figure" : "those figures") may read high")
        }
        let device = result.device
        self.init(
            id: Self.id(.gpu, result.date), kind: .gpu, date: result.date, workloadVersion: result.suiteVersion,
            settings: [
                BenchmarkSetting(name: "Compute", value: "\(configuration.computeThreads.formatted()) threads × "
                    + "\(configuration.computeIterations) steps"),
                BenchmarkSetting(name: "Memory buffer", value: Format.wholeBytes(UInt64(configuration.memoryBytes))),
                BenchmarkSetting(name: "Fill", value: "\(configuration.fillSize) × \(configuration.fillSize), \(configuration.fillLayers) layers"),
                Self.timing(warmUp: configuration.warmUpSeconds, repeats: configuration.repeats, seconds: configuration.repeatSeconds),
                BenchmarkSetting(name: "Seed", value: String(configuration.seed, radix: 16, uppercase: true)),
            ],
            build: BenchmarkBuild(app: result.appVersion, optimized: result.optimized),
            machine: BenchmarkMachine(key: device.key, name: [device.summary, device.model].compactMap { $0 }.joined(separator: " · ")),
            target: nil, osVersion: result.osVersion, conditions: conditions, measurements: measurements
        )
    }

    init(_ result: DiskSpeedResult) {
        let configuration = result.configuration
        var conditions: [String] = []
        if !result.bypassedCache { conditions.append("the volume ignored F_NOCACHE, so reads may have come from memory") }
        if !result.fullFlush { conditions.append("writes were flushed with fsync only, so the disk's cache may hold some") }
        let order: [(DiskSpeedPhase, String)] = [
            (.sequentialRead, "sequentialRead"), (.sequentialWrite, "sequentialWrite"),
            (.randomRead, "randomRead"), (.randomWrite, "randomWrite"),
        ]
        let measurements = order.map { phase, id in
            let measurement = result.measurement(phase)
            return phase.isSequential
                ? BenchmarkMeasurement(id: id, name: phase.title, value: measurement.bytesPerSecond / 1_000_000, unit: .megabytesPerSecond)
                : BenchmarkMeasurement(id: id, name: phase.title, value: measurement.operationsPerSecond, unit: .operationsPerSecond)
        }
        self.init(
            id: Self.id(.disk, result.date), kind: .disk, date: result.date, workloadVersion: result.version,
            settings: [
                BenchmarkSetting(name: "Test file", value: Format.wholeBytes(configuration.fileSize)),
                BenchmarkSetting(name: "Blocks", value: "\(Format.wholeBytes(UInt64(configuration.sequentialBlockSize))) in sequence, "
                    + "\(Format.wholeBytes(UInt64(configuration.randomBlockSize))) at random"),
                BenchmarkSetting(name: "Random phases", value: "\(Format.fixed(configuration.randomSeconds, 0)) s or "
                    + "\(configuration.randomOperationLimit.formatted()) operations"),
                BenchmarkSetting(name: "Queue depth", value: "\(configuration.queueDepth)"),
            ],
            build: nil, machine: nil,
            target: BenchmarkTarget(key: result.volume.key, name: result.volume.name, detail: result.folder),
            osVersion: nil, conditions: conditions, measurements: measurements
        )
    }

    init(_ result: NetworkQualityResult) {
        var measurements: [BenchmarkMeasurement] = []
        if let download = result.downloadBitsPerSecond {
            measurements.append(BenchmarkMeasurement(id: "download", name: "Download", value: download, unit: .bitsPerSecond))
        }
        if let upload = result.uploadBitsPerSecond {
            measurements.append(BenchmarkMeasurement(id: "upload", name: "Upload", value: upload, unit: .bitsPerSecond))
        }
        if let responsiveness = result.responsiveness {
            measurements.append(BenchmarkMeasurement(id: "responsiveness", name: "Responsiveness", value: responsiveness,
                                                     unit: .roundTripsPerMinute))
        }
        if let latency = result.idleLatency {
            measurements.append(BenchmarkMeasurement(id: "idleLatency", name: "Idle latency", value: latency, unit: .milliseconds))
        }
        self.init(
            id: Self.id(.network, result.date), kind: .network, date: result.date, workloadVersion: result.version,
            settings: [BenchmarkSetting(name: "Mode", value: result.arguments.contains("-s") ? "sequential" : "parallel")],
            build: nil, machine: nil,
            target: BenchmarkTarget(key: result.historyKey, name: result.historyKey, detail: result.endpoint),
            osVersion: result.toolVersion, conditions: [], measurements: measurements
        )
    }

    private static func timing(warmUp: Double, repeats: Int, seconds: Double) -> BenchmarkSetting {
        BenchmarkSetting(name: "Timing", value: "\(Format.fixed(warmUp, 1)) s warm-up, \(repeats) × \(Format.fixed(seconds, 1)) s repeats")
    }

    private static func conditions(thermal: ThermalState, lowPower: Bool) -> [String] {
        var conditions: [String] = []
        if thermal != .nominal { conditions.append("thermal pressure \(thermal.rawValue)") }
        if lowPower { conditions.append("Low Power Mode on") }
        return conditions
    }
}

// MARK: - Reading the histories

/// Every saved result of the four tests, read from their history files in
/// Application Support/OpenTaskManager/SpeedTests and adapted to
/// `BenchmarkRun` on the way: nothing is migrated or written back.
public struct BenchmarkLibrary: Sendable {
    public let folder: URL

    public init(folder: URL = SpeedTestHistory<CPUBenchmarkResult>.defaultFolder) {
        self.folder = folder
    }

    /// Every run, newest first.
    public func load() -> [BenchmarkRun] {
        let cpu = history(SpeedTestHistory<CPUBenchmarkResult>.cpuBenchmark).load().map(BenchmarkRun.init)
        let gpu = history(SpeedTestHistory<GPUBenchmarkResult>.gpuBenchmark).load().map(BenchmarkRun.init)
        let disk = history(SpeedTestHistory<DiskSpeedResult>.diskSpeed).load().map(BenchmarkRun.init)
        let network = history(SpeedTestHistory<NetworkQualityResult>.networkQuality).load().map(BenchmarkRun.init)
        return (cpu + gpu + disk + network).sorted { $0.date > $1.date }
    }

    /// The same file name as the app's own history, in `folder`.
    private func history<Record>(_ standard: SpeedTestHistory<Record>) -> SpeedTestHistory<Record> {
        SpeedTestHistory(file: folder.appendingPathComponent(standard.file.lastPathComponent), keptPerKey: standard.keptPerKey,
                         keptKeys: standard.keptKeys)
    }
}
