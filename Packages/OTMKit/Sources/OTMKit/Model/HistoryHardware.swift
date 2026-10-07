import Foundation

/// A hardware figure the flight recorder keeps beside the whole-system ones:
/// a core type's load, a cluster's clock, a fan, a temperature or a power
/// rail. Each is picked from what the samplers already read (the sensor
/// table's rows and the CPU's per-core load), a few per Mac rather than
/// every sensor, and named once with its unit and where it comes from, so a
/// recording says what its numbers are on a Mac that has none of them.
public struct HistoryHardwareSeries: Sendable, Hashable, Identifiable, Comparable {
    /// What the series measures, in the order the History page lists them.
    public enum Kind: String, Sendable, CaseIterable, Comparable {
        /// Load per core type, and the busiest core's.
        case load
        /// Each CPU cluster's clock while it runs, and the GPU's.
        case clock
        case temperature
        case fan
        case power

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
    }

    /// Stable for the same figure across records, launches and Macs:
    /// "cpu.load.super", "cpu.clock.MCPU0", "fan.0", "temperature.ssd".
    public let id: String
    public let kind: Kind
    public let unit: SensorUnit
    /// "Super cores", "Performance 1", "Fan 2", "SSD".
    public let label: String
    /// The counters or sensors behind it: "SMC F0Ac", "HID sensors PMU tdie*, hottest".
    public let source: String
    /// Its place among its kind's series.
    public let rank: Int

    public init(id: String, kind: Kind, unit: SensorUnit, label: String, source: String, rank: Int) {
        self.id = id
        self.kind = kind
        self.unit = unit
        self.label = label
        self.source = source
        self.rank = rank
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.id < rhs.id
    }

    /// The busiest logical CPU at each update.
    public static let busiestCore = "cpu.load.busiest"
}

/// One update's hardware figures for the flight recorder, picked from the
/// sensor table's rows and the CPU sample. A figure that wasn't read this
/// update (an idle cluster has no clock, stalled energy counters no power,
/// a VM no fans) is simply missing, never zero.
public struct HistoryHardwareSample: Sendable, Equatable {
    /// Each series' value, by `HistoryHardwareSeries.id`.
    public private(set) var values: [String: Double] = [:]
    /// The series with a value, in no particular order.
    public private(set) var series: [HistoryHardwareSeries] = []
    /// Each logical CPU's load, 0...1, by CPU number.
    public private(set) var coreLoads: [Double?] = []

    public init() {}

    /// Picks the figures from `readings` (this update's `SensorTable`
    /// rows) and `cpu`. `sensorsRead` is false on an update that didn't read
    /// the temperature sensors, fans and rails, whose rows then repeat the
    /// last reading: those are left out rather than counted again.
    public init(readings: [SensorReading], cpu: CPUSample, topology: CPUTopology, sensorsRead: Bool = true) {
        addLoads(cpu, topology: topology)
        let fresh = sensorsRead ? readings : readings.filter { !Self.comesFromSensors($0) }
        let usable = fresh.filter { $0.value?.isFinite == true }
        addClocks(usable)
        addTemperatures(usable)
        for reading in usable where reading.group == .fans && reading.unit == .rpm {
            guard let number = reading.id.split(separator: "/").last.flatMap({ Int($0) }), let rpm = reading.value, rpm >= 0 else { continue }
            add(HistoryHardwareSeries(id: "fan.\(number)", kind: .fan, unit: .rpm, label: reading.label,
                                      source: Self.describe(reading), rank: number), rpm)
        }
        let rails: KeyValuePairs<String, (id: String, label: String)> = [
            "ane/power": ("power.ane", "Neural Engine"), "dram/power": ("power.dram", "DRAM"), "power/input": ("power.input", "DC input"),
        ]
        for (rank, rail) in rails.enumerated() {
            guard let reading = usable.first(where: { $0.id == rail.key }), let watts = reading.value, watts >= 0 else { continue }
            add(HistoryHardwareSeries(id: rail.value.id, kind: .power, unit: .watts, label: rail.value.label, source: Self.describe(reading),
                                      rank: rank), watts)
        }
    }

    /// Adds a figure, or replaces one with the same series.
    public mutating func add(_ series: HistoryHardwareSeries, _ value: Double) {
        guard value.isFinite else { return }
        if values.updateValue(value, forKey: series.id) == nil {
            self.series.append(series)
        } else if let index = self.series.firstIndex(where: { $0.id == series.id }) {
            self.series[index] = series
        }
    }

    public mutating func setCoreLoads(_ loads: [Double?]) {
        coreLoads = loads.map { load in load.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } }
    }

    // MARK: - Picking

    /// Each core type's average load, when the Mac has more than one, and the busiest core's.
    private mutating func addLoads(_ cpu: CPUSample, topology: CPUTopology) {
        let usage = cpu.coreUsage
        setCoreLoads(usage)
        if let busiest = coreLoads.compactMap({ $0 }).max() {
            add(HistoryHardwareSeries(id: HistoryHardwareSeries.busiestCore, kind: .load, unit: .fraction, label: "Busiest core",
                                      source: "host_processor_info, the busiest logical CPU at each update", rank: 90), busiest)
        }
        // Tiers only when the map from CPU to tier matches the CPUs counted.
        guard topology.tiers.count > 1, topology.tierForCPU.count == usage.count else { return }
        for tier in topology.tiers {
            let loads = usage.indices.filter { topology.tierForCPU[$0] == tier.level }.compactMap { coreLoads[$0] }
            guard !loads.isEmpty, loads.count == tier.logicalCPUs else { continue }
            add(HistoryHardwareSeries(id: "cpu.load.\(Self.key(tier.name))", kind: .load, unit: .fraction, label: "\(tier.name) cores",
                                      source: "host_processor_info, mean of the \(loads.count) logical CPUs at hw.perflevel\(tier.level)",
                                      rank: tier.level),
                loads.reduce(0, +) / Double(loads.count))
        }
    }

    /// Each CPU cluster's clock and the GPU's, from IOReport's residency; an
    /// idle one has none.
    private mutating func addClocks(_ readings: [SensorReading]) {
        for reading in readings where reading.unit == .megahertz {
            guard let megahertz = reading.value, megahertz > 0 else { continue }
            let parts = reading.id.split(separator: "/")
            if reading.group == .cpu, parts.count == 3, parts[0] == "cpu", parts[2] == "clock" {
                let label = reading.label.hasSuffix(" clock") ? String(reading.label.dropLast(" clock".count)) : reading.label
                add(HistoryHardwareSeries(id: "cpu.clock.\(parts[1])", kind: .clock, unit: .megahertz, label: label,
                                          source: "IOReport \(parts[1]) residency, device-tree clocks", rank: reading.rank), megahertz)
            } else if reading.group == .gpu, values["gpu.clock"] == nil {
                add(HistoryHardwareSeries(id: "gpu.clock", kind: .clock, unit: .megahertz, label: "GPU",
                                          source: "IOReport GPU residency, device-tree clocks", rank: 100), megahertz)
            }
        }
    }

    /// The hottest CPU and GPU die sensors (M1 and M2 name them), the die's
    /// average, the SSD's and the battery's.
    private mutating func addTemperatures(_ readings: [SensorReading]) {
        let celsius = readings.filter { $0.unit == .celsius && $0.source != .derived }
        let picks: KeyValuePairs<SensorGroup, (id: String, label: String)> = [
            .cpu: ("temperature.cpu", "CPU die"), .gpu: ("temperature.gpu", "GPU die"),
            .storage: ("temperature.ssd", "SSD"), .battery: ("temperature.battery", "Battery"),
        ]
        for (rank, pick) in picks.enumerated() {
            let sensors = celsius.filter { $0.group == pick.key }
            guard let hottest = sensors.compactMap(\.value).max() else { continue }
            add(HistoryHardwareSeries(id: pick.value.id, kind: .temperature, unit: .celsius, label: pick.value.label,
                                      source: Self.describe(sensors, summary: "hottest"), rank: rank < 2 ? rank : rank + 1), hottest)
        }
        if let average = readings.first(where: { $0.id == "chip/average" })?.value {
            let dies = celsius.filter { $0.id.hasPrefix("temperature/") && ($0.group == .chip || $0.group == .cpu || $0.group == .gpu) }
            add(HistoryHardwareSeries(id: "temperature.average", kind: .temperature, unit: .celsius, label: "Die average",
                                      source: dies.isEmpty ? "chip/average" : Self.describe(dies, summary: "mean"), rank: 2), average)
        }
    }

    /// Rows read from the temperature sensors, fans and SMC rails, which an
    /// update that skips the sensors repeats from the last one.
    private static func comesFromSensors(_ reading: SensorReading) -> Bool {
        ["temperature/", "chip/", "fan/", "rail/"].contains { reading.id.hasPrefix($0) }
    }

    /// "Super" → "super"; anything but letters and digits becomes "-".
    static func key(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Where one reading comes from: "SMC F0Ac", "IOReport ANE".
    static func describe(_ reading: SensorReading) -> String {
        [reading.source.shortTitle, reading.origin].compactMap { $0 }.joined(separator: " ")
    }

    /// Where a figure over several readings comes from, its sensors' names
    /// with their numbers folded: "HID sensors PMU tdie*, hottest".
    static func describe(_ readings: [SensorReading], summary: String) -> String {
        guard readings.count > 1 else { return readings.first.map(describe) ?? summary }
        let names = Set(readings.map { reading -> String in
            let name = reading.origin ?? reading.id
            let stem = name.reversed().drop { $0.isNumber }.reversed()
            return stem.count < name.count ? String(stem) + "*" : name
        })
        let source = readings[0].source.shortTitle
        return "\(source) \(names.sorted().joined(separator: ", ")), \(summary)"
    }
}

/// The hardware series between two dates as graph points: each series and
/// each core averaged per bucket of the History page's graphs, over the
/// records that have it, keyed as `FlightRecorder.points` groups its points.
public struct HistoryHardwareTrack: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable {
        public var values: [String: Double]
        public var coreLoads: [Double?]
    }

    public let bucket: TimeInterval
    /// Every series with a value in the range, in chart order.
    public let series: [HistoryHardwareSeries]
    /// The most logical CPUs any record in the range holds a load for.
    public let coreCount: Int
    /// When the recording's first hardware figures were written, if any.
    public let earliest: Date?
    let buckets: [Int: Bucket]

    public static let empty = HistoryHardwareTrack(records: [], series: [], bucket: FlightRecorder.span, earliest: nil)

    public var isEmpty: Bool { series.isEmpty && coreCount == 0 }

    /// Averages `records`' hardware figures into buckets of `bucket`
    /// seconds. Gaps stay gaps: a bucket without a record has no entry, and
    /// a series missing from every record in one is missing from it.
    public init(records: [HistoryRecord], series: [HistoryHardwareSeries], bucket: TimeInterval, earliest: Date?) {
        self.bucket = max(bucket, FlightRecorder.span)
        self.earliest = earliest
        var sums: [Int: (values: [String: (sum: Double, count: Int)], cores: [(sum: Double, count: Int)])] = [:]
        for record in records {
            let key = Self.key(record.time, bucket: self.bucket)
            var entry = sums[key] ?? ([:], [])
            for (id, value) in record.values.hardware where value.isFinite {
                let previous = entry.values[id] ?? (0, 0)
                entry.values[id] = (previous.sum + value, previous.count + 1)
            }
            if entry.cores.count < record.values.coreLoads.count {
                entry.cores += Array(repeating: (0, 0), count: record.values.coreLoads.count - entry.cores.count)
            }
            for (index, load) in record.values.coreLoads.enumerated() {
                guard let load, load.isFinite else { continue }
                entry.cores[index] = (entry.cores[index].sum + load, entry.cores[index].count + 1)
            }
            sums[key] = entry
        }
        buckets = sums.mapValues { entry in
            Bucket(values: entry.values.mapValues { $0.sum / Double($0.count) },
                   coreLoads: entry.cores.map { $0.count > 0 ? $0.sum / Double($0.count) : nil })
        }
        let present = Set(buckets.values.flatMap(\.values.keys))
        self.series = series.filter { present.contains($0.id) }.sorted()
        coreCount = buckets.values.map { $0.coreLoads.contains { $0 != nil } ? $0.coreLoads.count : 0 }.max() ?? 0
    }

    /// `points` (from `FlightRecorder.points` with the same bucket) with
    /// their hardware figures filled in from the bucket each one closes.
    /// A point whose bucket has none keeps none, so its lines break there.
    public func overlay(_ points: [HistoryPoint]) -> [HistoryPoint] {
        guard !buckets.isEmpty else { return points }
        return points.map { point in
            guard let entry = buckets[Self.key(point.time, bucket: bucket)] else { return point }
            var values = point.values
            values.hardware = entry.values
            values.coreLoads = entry.coreLoads
            return HistoryPoint(time: point.time, values: values, segment: point.segment)
        }
    }

    /// The bucket a time falls in, numbered as SQLite's `CAST(time / bucket AS INTEGER)`.
    static func key(_ time: Date, bucket: TimeInterval) -> Int {
        Int((time.timeIntervalSince1970 / bucket).rounded(.towardZero))
    }
}
