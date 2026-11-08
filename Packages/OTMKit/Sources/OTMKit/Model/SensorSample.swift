import Foundation

/// Where a temperature sensor sits.
public enum SensorKind: String, Sendable, Codable, CaseIterable {
    /// The system on a chip's die sensors.
    case chip
    case storage
    case battery

    public var title: String {
        switch self {
        case .chip: "Chip"
        case .storage: "SSD"
        case .battery: "Battery"
        }
    }
}

/// One reading of the Mac's temperature sensors, fans and the SMC's
/// electrical rails.
public struct SensorSample: Sendable, Codable {
    public struct Temperature: Sendable, Codable, Identifiable, Hashable {
        public var id: String { name }
        /// The sensor's own name, e.g. "PMU tdie3".
        public let name: String
        /// A readable name, e.g. "Die 3".
        public let label: String
        public let kind: SensorKind
        /// The part of the Mac the sensor table lists it under.
        public let group: SensorGroup
        public let celsius: Double
    }

    public struct Fan: Sendable, Codable, Identifiable, Hashable {
        public let id: Int
        public let rpm: Double
        public let minimumRPM: Double?
        public let maximumRPM: Double?

        /// Its speed as a share of its fastest, 0...1: the scale its graph and
        /// the Thermals table's bar draw it on, from zero. A fan turning at its
        /// minimum reads above zero, never as stopped. Nil when the SMC doesn't
        /// publish the maximum.
        public var shareOfMaximum: Double? {
            guard let maximumRPM, maximumRPM > 0 else { return nil }
            return min(max(rpm / maximumRPM, 0), 1)
        }

        /// Fans on Apple silicon laptops stop entirely when cool.
        public var isStopped: Bool { rpm < 1 }
    }

    /// A voltage or current the SMC reports under a key whose meaning is
    /// known (see `SMCRail`).
    public struct Rail: Sendable, Codable, Identifiable, Hashable {
        /// The SMC key, e.g. "VD0R".
        public let id: String
        public let label: String
        public let unit: SensorUnit
        public let value: Double

        public init(id: String, label: String, unit: SensorUnit, value: Double) {
            self.id = id
            self.label = label
            self.unit = unit
            self.value = value
        }
    }

    public let temperatures: [Temperature]
    public let fans: [Fan]
    public let rails: [Rail]

    public init(temperatures: [Temperature], fans: [Fan], rails: [Rail] = []) {
        self.temperatures = temperatures
        self.fans = fans
        self.rails = rails
    }

    public var isEmpty: Bool { temperatures.isEmpty && fans.isEmpty && rails.isEmpty }

    public func hottest(_ kind: SensorKind) -> Double? {
        temperatures.filter { $0.kind == kind }.map(\.celsius).max()
    }

    public func average(_ kind: SensorKind) -> Double? {
        let readings = temperatures.filter { $0.kind == kind }.map(\.celsius)
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }
}

/// Turns raw sensor names and readings into labelled temperatures.
public enum SensorModel {
    /// Readings outside this range come from sensors that aren't really
    /// thermometers (some report about −9200 °C) and are dropped.
    static let plausible = -20.0...130.0

    /// What a sensor's name says about it.
    public struct Classification: Sendable, Equatable {
        public let kind: SensorKind
        /// A readable name, e.g. "Die 3".
        public let label: String
        /// The part of the Mac the sensor table lists it under.
        public let group: SensorGroup
    }

    /// An on-chip sensor family that says which block it sits in.
    private struct BlockSensor {
        let prefix: String
        let group: SensorGroup
        /// The label before the sensor's number.
        let label: String
    }

    /// The HID names of on-chip sensors that say which block they sit in,
    /// as M1 and M2 chips publish them ("pACC MTR Temp Sensor2").
    private static let blockSensors = [
        BlockSensor(prefix: "pACC MTR Temp Sensor", group: .cpu, label: "Performance cores"),
        BlockSensor(prefix: "eACC MTR Temp Sensor", group: .cpu, label: "Efficiency cores"),
        BlockSensor(prefix: "GPU MTR Temp Sensor", group: .gpu, label: "GPU"),
        BlockSensor(prefix: "ANE MTR Temp Sensor", group: .neuralEngine, label: "Neural Engine"),
        BlockSensor(prefix: "SOC MTR Temp Sensor", group: .chip, label: "SoC"),
        BlockSensor(prefix: "PMGR SOC Die Temp Sensor", group: .chip, label: "Power manager"),
        BlockSensor(prefix: "ISP MTR Temp Sensor", group: .other, label: "Image processor"),
    ]

    /// The kind, readable label and table group for a sensor the app shows,
    /// or nil for the ones it skips (calibration and device sensors with no
    /// clear meaning).
    public static func classify(_ name: String) -> Classification? {
        if name.hasPrefix("PMU tdie"), let number = Int(name.dropFirst("PMU tdie".count)) {
            return Classification(kind: .chip, label: "Die \(number)", group: .chip)
        }
        if name.hasPrefix("NAND") {
            let channel = name.split(separator: " ").first { $0.hasPrefix("CH") }.flatMap { Int($0.dropFirst(2)) }
            return Classification(kind: .storage, label: channel.map { "SSD channel \($0)" } ?? "SSD", group: .storage)
        }
        if name.localizedCaseInsensitiveContains("battery") {
            return Classification(kind: .battery, label: "Battery", group: .battery)
        }
        for block in blockSensors where name.hasPrefix(block.prefix) {
            guard let number = Int(name.dropFirst(block.prefix.count)) else { return nil }
            // On the die, so they count toward the chip's hottest and average.
            return Classification(kind: .chip, label: "\(block.label) \(number)", group: block.group)
        }
        return nil
    }

    /// One temperature per sensor name: several power controllers publish the
    /// same names, so each keeps its hottest reading. Sorted by kind, then
    /// naturally by label ("Die 2" before "Die 10").
    public static func temperatures(from readings: [(name: String, celsius: Double)]) -> [SensorSample.Temperature] {
        var hottest: [String: Double] = [:]
        for reading in readings where plausible.contains(reading.celsius) && classify(reading.name) != nil {
            hottest[reading.name] = max(hottest[reading.name] ?? -.infinity, reading.celsius)
        }
        let order = Dictionary(uniqueKeysWithValues: SensorKind.allCases.enumerated().map { ($1, $0) })
        return hottest.compactMap { name, celsius -> SensorSample.Temperature? in
            guard let sensor = classify(name) else { return nil }
            return SensorSample.Temperature(name: name, label: sensor.label, kind: sensor.kind, group: sensor.group, celsius: celsius)
        }
        .sorted {
            if $0.kind != $1.kind { return order[$0.kind, default: 0] < order[$1.kind, default: 0] }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
}

/// SMC keys for voltages and currents whose meaning holds up: on an M5 Pro
/// with a 140 W adapter, VD0R (27.87 V) times ID0R (0.102 A) came to PDTR,
/// the DC input power the Power page already uses (2.84 W). The SMC has
/// hundreds more rail keys, but nothing says what they measure, so they're
/// left out rather than labelled by guesswork.
public enum SMCRail {
    /// A rail key and what it measures.
    public struct Key: Sendable {
        public let key: String
        public let label: String
        public let unit: SensorUnit
    }

    public static let keys = [
        Key(key: "VD0R", label: "DC input voltage", unit: .volts),
        Key(key: "ID0R", label: "DC input current", unit: .amperes),
    ]

    /// Readings outside these are an unpopulated or misread key. The largest
    /// USB-C supply is 48 V; Mac desktops' internal supplies run at 12 V.
    static let plausible: [SensorUnit: ClosedRange<Double>] = [.volts: 0...60, .amperes: 0...30]

    /// The rail for one key's raw reading, or nil when the reading is missing or implausible.
    public static func rail(key: String, label: String, unit: SensorUnit, value: Double?) -> SensorSample.Rail? {
        guard let value, value.isFinite, plausible[unit]?.contains(value) ?? false else { return nil }
        return SensorSample.Rail(id: key, label: label, unit: unit, value: value)
    }
}
