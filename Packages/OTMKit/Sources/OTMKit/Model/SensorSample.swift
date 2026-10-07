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

/// One reading of the Mac's temperature sensors and fans.
public struct SensorSample: Sendable, Codable {
    public struct Temperature: Sendable, Codable, Identifiable, Hashable {
        public var id: String { name }
        /// The sensor's own name, e.g. "PMU tdie3".
        public let name: String
        /// A readable name, e.g. "Die 3".
        public let label: String
        public let kind: SensorKind
        public let celsius: Double
    }

    public struct Fan: Sendable, Codable, Identifiable, Hashable {
        public let id: Int
        public let rpm: Double
        public let minimumRPM: Double?
        public let maximumRPM: Double?

        /// How far between its slowest and fastest speed the fan is running,
        /// 0...1. Nil when the SMC doesn't publish the range.
        public var fraction: Double? {
            guard let minimumRPM, let maximumRPM, maximumRPM > minimumRPM else { return nil }
            return min(max((rpm - minimumRPM) / (maximumRPM - minimumRPM), 0), 1)
        }

        /// Fans on Apple silicon laptops stop entirely when cool.
        public var isStopped: Bool { rpm < 1 }
    }

    public let temperatures: [Temperature]
    public let fans: [Fan]

    public init(temperatures: [Temperature], fans: [Fan]) {
        self.temperatures = temperatures
        self.fans = fans
    }

    public var isEmpty: Bool { temperatures.isEmpty && fans.isEmpty }

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

    /// The kind and readable label for a sensor the app shows, or nil for the
    /// ones it skips (calibration and device sensors with no clear meaning).
    public static func classify(_ name: String) -> (kind: SensorKind, label: String)? {
        if name.hasPrefix("PMU tdie"), let number = Int(name.dropFirst("PMU tdie".count)) {
            return (.chip, "Die \(number)")
        }
        if name.hasPrefix("NAND") {
            let channel = name.split(separator: " ").first { $0.hasPrefix("CH") }.flatMap { Int($0.dropFirst(2)) }
            return (.storage, channel.map { "SSD channel \($0)" } ?? "SSD")
        }
        if name.localizedCaseInsensitiveContains("battery") {
            return (.battery, "Battery")
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
            guard let (kind, label) = classify(name) else { return nil }
            return SensorSample.Temperature(name: name, label: label, kind: kind, celsius: celsius)
        }
        .sorted {
            if $0.kind != $1.kind { return order[$0.kind, default: 0] < order[$1.kind, default: 0] }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
}
