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
        gpu = snapshot.gpus.map(\.deviceUtilization).max()
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

    public init(time: Date, values: HistoryValues, topCPU: [HistoryApp] = [], topMemory: [HistoryApp] = []) {
        self.time = time
        self.values = values
        self.topCPU = topCPU
        self.topMemory = topMemory
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

    public init(span: TimeInterval) {
        self.span = span
        optionalCovered = Array(repeating: 0, count: HistoryValues.optional.count)
    }

    /// Adds one tick covering `interval` seconds up to `time`. Returns the
    /// finished stretch once `span` seconds are covered.
    ///
    /// A tick longer than a whole stretch (the first after a pause or sleep)
    /// is dropped, and a gap between ticks starts a fresh stretch, so a
    /// record never spans time the app didn't watch.
    public mutating func add(_ values: HistoryValues, apps: [AppUsage], interval: TimeInterval, at time: Date) -> HistoryRecord? {
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
        let record = HistoryRecord(
            time: time, values: average,
            topCPU: HistoryRecord.ranked(appCPU.mapValues { $0 / covered }, count: Self.appsKept),
            topMemory: HistoryRecord.ranked(appMemory, count: Self.appsKept)
        )
        reset()
        last = time
        return record
    }

    private mutating func reset() {
        covered = 0
        last = nil
        sum = HistoryValues()
        optionalCovered = optionalCovered.map { _ in 0 }
        peak = 0
        appCPU = [:]
        appMemory = [:]
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
}
