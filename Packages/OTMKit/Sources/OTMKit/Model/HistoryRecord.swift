import Foundation

/// The whole-system figures the flight recorder keeps. Rates are per second;
/// fractions run 0...1.
public struct HistoryValues: Sendable, Equatable {
    public var cpu = 0.0
    /// The busiest single tick in the stretch; the others are averages.
    public var cpuPeak = 0.0
    public var memory = 0.0
    public var memoryPressure = 0.0
    public var swapUsed = 0.0
    /// The busiest GPU's load. Nil on a Mac or VM without GPU statistics.
    public var gpu: Double?
    public var systemWatts: Double?
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var diskRead = 0.0
    public var diskWrite = 0.0
    public var networkIn = 0.0
    public var networkOut = 0.0
    public var chipCelsius: Double?
    /// Hardware figures by `HistoryHardwareSeries.id`, averaged over the
    /// updates that read them. A series missing here wasn't read: null, never zero.
    public var hardware: [String: Double] = [:]
    /// Each logical CPU's load, 0...1, by CPU number; nil for a CPU with no
    /// reading, and empty when none were recorded.
    public var coreLoads: [Double?] = []

    public init() {}

    /// The figures from one snapshot. Network counts only real links that
    /// are up, so a VPN's traffic isn't counted twice.
    public init(_ snapshot: SystemSnapshot, chipCelsius: Double?) {
        let memory = snapshot.memory
        let parts = snapshot.power.components
        cpu = snapshot.cpu.usage
        cpuPeak = snapshot.cpu.usage
        self.memory = memory.usedFraction
        memoryPressure = memory.availablePercent.map { 1 - Double($0) / 100 } ?? memory.usedFraction
        swapUsed = Double(memory.swapUsed)
        gpu = snapshot.gpus.compactMap(\.deviceUtilization).max()
        systemWatts = snapshot.power.systemWatts
        cpuWatts = parts?.watts(.cpu)
        gpuWatts = parts?.watts(.gpu)
        diskRead = snapshot.disks.reduce(0) { $0 + $1.readBytesPerSecond }
        diskWrite = snapshot.disks.reduce(0) { $0 + $1.writeBytesPerSecond }
        let links = snapshot.network.filter(\.isPrimary)
        networkIn = links.reduce(0) { $0 + $1.receivedBytesPerSecond }
        networkOut = links.reduce(0) { $0 + $1.sentBytesPerSecond }
        self.chipCelsius = chipCelsius
    }

    /// Figures every snapshot has, averaged over a stretch.
    static var averaged: [WritableKeyPath<Self, Double>] {
        [\.cpu, \.memory, \.memoryPressure, \.swapUsed, \.diskRead, \.diskWrite, \.networkIn, \.networkOut]
    }

    /// Figures a Mac may not report, averaged over the ticks that have them.
    static var optional: [WritableKeyPath<Self, Double?>] {
        [\.gpu, \.systemWatts, \.cpuWatts, \.gpuWatts, \.chipCelsius]
    }
}

/// An app's share of a resource: CPU in Activity Monitor percent (100 = one
/// core) or memory in bytes.
public struct HistoryApp: Sendable, Equatable, Codable {
    public let name: String
    public let value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case value = "v"
    }
}

/// What an app was using at one tick, for the recorder's top-app lists.
public struct AppUsage: Sendable {
    public let name: String
    public let cpuPercent: Double
    public let memory: Double

    public init(name: String, cpuPercent: Double, memory: Double) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memory = memory
    }
}

/// One stretch of the flight recorder: its figures and the apps that used
/// the most CPU and memory in it.
public struct HistoryRecord: Sendable, Equatable {
    /// The end of the stretch.
    public var time: Date
    public var values: HistoryValues
    public var topCPU: [HistoryApp]
    public var topMemory: [HistoryApp]
    /// What each of `values.hardware`'s series is, in chart order.
    public var hardwareSeries: [HistoryHardwareSeries]

    public init(time: Date, values: HistoryValues, topCPU: [HistoryApp] = [], topMemory: [HistoryApp] = [],
                hardwareSeries: [HistoryHardwareSeries] = []) {
        self.time = time
        self.values = values
        self.topCPU = topCPU
        self.topMemory = topMemory
        self.hardwareSeries = hardwareSeries
    }

    /// The top apps across several stretches: CPU averaged over all of them
    /// (an app missing from a stretch's list counts as idle there), memory at
    /// its highest.
    public static func topApps(in records: [HistoryRecord], count: Int) -> (cpu: [HistoryApp], memory: [HistoryApp]) {
        guard !records.isEmpty else { return ([], []) }
        var cpu: [String: Double] = [:]
        var memory: [String: Double] = [:]
        for record in records {
            for app in record.topCPU { cpu[app.name, default: 0] += app.value / Double(records.count) }
            for app in record.topMemory { memory[app.name] = max(memory[app.name] ?? 0, app.value) }
        }
        return (ranked(cpu, count: count), ranked(memory, count: count))
    }

    static func ranked(_ totals: [String: Double], count: Int) -> [HistoryApp] {
        totals.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(count)
            .map { HistoryApp(name: $0.key, value: $0.value) }
    }
}

/// Folds sampling ticks into flight-recorder stretches of `span` seconds,
/// weighting each tick by how long it covers, so a change of update speed
/// doesn't skew the averages.
public struct HistoryAccumulator: Sendable {
    public static let appsKept = 5

    public let span: TimeInterval
    private var covered = 0.0
    private var last: Date?
    private var sum = HistoryValues()
    private var optionalCovered: [Double]
    private var peak = 0.0
    private var appCPU: [String: Double] = [:]
    private var appMemory: [String: Double] = [:]
    /// Hardware figures times the seconds they cover, and those seconds.
    private var hardware: [String: (sum: Double, covered: Double)] = [:]
    private var hardwareSeries: [String: HistoryHardwareSeries] = [:]
    private var cores: [(sum: Double, covered: Double)] = []

    public init(span: TimeInterval) {
        self.span = span
        optionalCovered = Array(repeating: 0, count: HistoryValues.optional.count)
    }

    /// Adds one tick covering `interval` seconds up to `time`. Returns the
    /// finished stretch once `span` seconds are covered.
    ///
    /// A tick longer than a whole stretch (the first after a pause or sleep)
    /// is dropped, and a gap between ticks starts a fresh stretch, so a
    /// record never spans time the app didn't watch. Each of `hardware`'s
    /// figures is averaged over the ticks that read it, as the optional
    /// figures are.
    public mutating func add(_ values: HistoryValues, hardware sample: HistoryHardwareSample? = nil, apps: [AppUsage],
                             interval: TimeInterval, at time: Date) -> HistoryRecord? {
        if let last, time.timeIntervalSince(last) > interval + span || interval > span {
            reset()
        }
        guard interval > 0, interval <= span else { return nil }
        last = time
        covered += interval
        for path in HistoryValues.averaged { sum[keyPath: path] += values[keyPath: path] * interval }
        for (index, path) in HistoryValues.optional.enumerated() {
            guard let value = values[keyPath: path] else { continue }
            sum[keyPath: path] = (sum[keyPath: path] ?? 0) + value * interval
            optionalCovered[index] += interval
        }
        peak = max(peak, values.cpuPeak)
        if let sample { add(sample, interval: interval) }
        for app in apps {
            if app.cpuPercent > 0 { appCPU[app.name, default: 0] += app.cpuPercent * interval }
            appMemory[app.name] = max(appMemory[app.name] ?? 0, app.memory)
        }
        guard covered >= span - 0.001 else { return nil }

        var average = HistoryValues()
        for path in HistoryValues.averaged { average[keyPath: path] = sum[keyPath: path] / covered }
        for (index, path) in HistoryValues.optional.enumerated() where optionalCovered[index] > 0 {
            average[keyPath: path] = sum[keyPath: path].map { $0 / optionalCovered[index] }
        }
        average.cpuPeak = peak
        average.hardware = hardware.compactMapValues { $0.covered > 0 ? $0.sum / $0.covered : nil }
        average.coreLoads = cores.map { $0.covered > 0 ? $0.sum / $0.covered : nil }
        let record = HistoryRecord(
            time: time, values: average,
            topCPU: HistoryRecord.ranked(appCPU.mapValues { $0 / covered }, count: Self.appsKept),
            topMemory: HistoryRecord.ranked(appMemory, count: Self.appsKept),
            hardwareSeries: hardwareSeries.values.filter { average.hardware[$0.id] != nil }.sorted()
        )
        reset()
        last = time
        return record
    }

    private mutating func add(_ sample: HistoryHardwareSample, interval: TimeInterval) {
        for (id, value) in sample.values where value.isFinite {
            let previous = hardware[id] ?? (0, 0)
            hardware[id] = (previous.sum + value * interval, previous.covered + interval)
        }
        for series in sample.series { hardwareSeries[series.id] = series }
        if cores.count < sample.coreLoads.count {
            cores += Array(repeating: (0, 0), count: sample.coreLoads.count - cores.count)
        }
        for (index, load) in sample.coreLoads.enumerated() {
            guard let load else { continue }
            cores[index] = (cores[index].sum + load * interval, cores[index].covered + interval)
        }
    }

    private mutating func reset() {
        covered = 0
        last = nil
        sum = HistoryValues()
        optionalCovered = optionalCovered.map { _ in 0 }
        peak = 0
        appCPU = [:]
        appMemory = [:]
        hardware = [:]
        hardwareSeries = [:]
        cores = []
    }
}

/// A point on a history graph: the average of the records in one bucket.
public struct HistoryPoint: Sendable, Identifiable, Equatable {
    public var id: Date { time }
    public let time: Date
    public let values: HistoryValues
    /// Increases after each gap in the recording (the app wasn't running, or
    /// the Mac slept), so graphs break the line there instead of bridging it.
    public var segment: Int

    public init(time: Date, values: HistoryValues, segment: Int = 0) {
        self.time = time
        self.values = values
        self.segment = segment
    }

    /// Numbers the runs of points that sit no more than `gap` seconds apart.
    public static func segmented(_ points: [HistoryPoint], gap: TimeInterval) -> [HistoryPoint] {
        var segment = 0
        var previous: Date?
        return points.map { point in
            if let previous, point.time.timeIntervalSince(previous) > gap { segment += 1 }
            previous = point.time
            var point = point
            point.segment = segment
            return point
        }
    }

    /// The point closest to `time` among `points`, which run oldest first.
    /// A tie goes to the earlier point.
    public static func nearest(to time: Date, in points: [HistoryPoint]) -> HistoryPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let middle = (low + high) / 2
            if points[middle].time < time { low = middle + 1 } else { high = middle }
        }
        // `low` is now the first point at or after `time`, or the last point.
        if low > 0, time.timeIntervalSince(points[low - 1].time) <= points[low].time.timeIntervalSince(time) {
            return points[low - 1]
        }
        return points[low]
    }

    /// Where a line through `points` runs unbroken: each point's run, nil
    /// where `value` has nothing for it. A run ends at a gap (the segment
    /// changes) and at a point without a value, so a graph never draws a
    /// line across a missing reading.
    public static func runs(_ points: [HistoryPoint], value: (HistoryValues) -> Double?) -> [Int?] {
        var run = -1
        var previous: HistoryPoint?
        var previousHad = false
        return points.map { point in
            defer { previous = point }
            guard value(point.values) != nil else {
                previousHad = false
                return nil
            }
            if !previousHad || previous?.segment != point.segment { run += 1 }
            previousHad = true
            return run
        }
    }

    /// The points (by index) where a line breaks off for a missing reading
    /// and where it picks up again, within a segment: `runs`' ends that
    /// border a point without a value rather than a gap.
    public static func breaks(_ points: [HistoryPoint], runs: [Int?]) -> [Int] {
        points.indices.filter { index in
            guard index < runs.count, runs[index] != nil else { return false }
            let before = index > 0 && runs[index - 1] == nil && points[index - 1].segment == points[index].segment
            let after = index + 1 < points.count && index + 1 < runs.count && runs[index + 1] == nil
                && points[index + 1].segment == points[index].segment
            return before || after
        }
    }

    /// The `runs` too short on the chart to fill under: those whose stretch
    /// within `domain` lasts less than `minimumSpan` seconds, a run of one
    /// point among them. A fill a few points wide reads as a bar rising from
    /// the axis rather than a stretch of readings; such a run keeps its line,
    /// with a dot at each end (`ends`), so a single reading is a dot.
    public static func unfilled(_ points: [HistoryPoint], runs: [Int?], within domain: ClosedRange<Date>,
                                minimumSpan: TimeInterval) -> Set<Int> {
        var spans: [Int: (first: Date, last: Date)] = [:]
        for (point, run) in zip(points, runs) {
            guard let run else { continue }
            spans[run] = (spans[run]?.first ?? point.time, point.time)
        }
        return Set(spans.compactMap { run, span in
            // Only what the chart shows of it counts: a run that starts before the window is cut at its edge.
            let shown = min(span.last, domain.upperBound).timeIntervalSince(max(span.first, domain.lowerBound))
            return shown < minimumSpan ? run : nil
        })
    }

    /// The first and last point (by index) of each of `chosen` among
    /// `runs`, oldest first; one index for a run of one point.
    public static func ends(of chosen: Set<Int>, in runs: [Int?]) -> [Int] {
        guard !chosen.isEmpty else { return [] }
        var ends: [Int: (first: Int, last: Int)] = [:]
        for (index, run) in runs.enumerated() {
            guard let run, chosen.contains(run) else { continue }
            ends[run] = (ends[run]?.first ?? index, index)
        }
        return Set(ends.values.flatMap { [$0.first, $0.last] }).sorted()
    }
}

// MARK: - Export

extension HistoryRecord {
    static let csvHeader = [
        "time", "cpu_percent", "cpu_peak_percent", "memory_percent", "memory_pressure_percent", "swap_bytes",
        "gpu_percent", "system_watts", "cpu_watts", "gpu_watts", "disk_read_bytes_per_s", "disk_write_bytes_per_s",
        "network_in_bytes_per_s", "network_out_bytes_per_s", "chip_celsius", "top_cpu_apps", "top_memory_apps",
    ]

    /// The records as CSV, one row per record, with ISO 8601 times. CPU
    /// for apps is in Activity Monitor percent (100 = one core). Figures the
    /// Mac didn't report are left empty. Hardware series, when the records
    /// have any, follow in chart order ("fan_0_rpm"), then each core's load.
    public static func csv(_ records: [HistoryRecord]) -> String {
        func number(_ value: Double?, scale: Double = 1, digits: Int = 2) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.\(digits)f", value * scale)
        }
        func field(_ text: String) -> String {
            guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let time = ISO8601DateFormatter()
        let series = Set(records.flatMap(\.hardwareSeries)).sorted()
        let cores = records.map(\.values.coreLoads.count).max() ?? 0
        let header = csvHeader + series.map(csvColumn) + (0..<cores).map { "core_\($0)_percent" }
        var lines = [header.joined(separator: ",")]
        for record in records {
            let values = record.values
            let row = [
                time.string(from: record.time),
                number(values.cpu, scale: 100, digits: 1), number(values.cpuPeak, scale: 100, digits: 1),
                number(values.memory, scale: 100, digits: 1), number(values.memoryPressure, scale: 100, digits: 1),
                number(values.swapUsed, digits: 0), number(values.gpu, scale: 100, digits: 1),
                number(values.systemWatts), number(values.cpuWatts), number(values.gpuWatts),
                number(values.diskRead, digits: 0), number(values.diskWrite, digits: 0),
                number(values.networkIn, digits: 0), number(values.networkOut, digits: 0),
                number(values.chipCelsius, digits: 1),
                field(record.topCPU.map { "\($0.name) \(number($0.value, digits: 1))%" }.joined(separator: "; ")),
                field(record.topMemory.map { "\($0.name) \(Format.bytes($0.value))" }.joined(separator: "; ")),
            ] + series.map { series in
                let fraction = series.unit == .fraction
                return number(values.hardware[series.id], scale: fraction ? 100 : 1, digits: fraction || series.unit == .celsius ? 1 : 2)
            } + (0..<cores).map { index in
                number(index < values.coreLoads.count ? values.coreLoads[index] : nil, scale: 100, digits: 1)
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A hardware series' CSV column: its ID and unit, "cpu_load_super_percent".
    static func csvColumn(_ series: HistoryHardwareSeries) -> String {
        let unit = switch series.unit {
        case .fraction: "percent"
        case .megahertz: "mhz"
        case .celsius: "celsius"
        default: series.unit.rawValue
        }
        let key = series.id.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return "\(key)_\(unit)"
    }
}
