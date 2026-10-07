import Foundation

/// The part of the Mac a row of the sensor table belongs to, in table order.
public enum SensorGroup: String, Sendable, Codable, CaseIterable, Comparable {
    /// Die sensors that don't belong to one block, and figures over all of them.
    case chip
    case cpu
    case gpu
    case neuralEngine
    case memory
    case storage
    case battery
    /// Whole-system power and the adapter's input.
    case power
    case fans
    case other

    public var title: String {
        switch self {
        case .chip: "Chip"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        case .memory: "Memory"
        case .storage: "SSD"
        case .battery: "Battery"
        case .power: "Power"
        case .fans: "Fans"
        case .other: "Other"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// What a sensor reading measures, and how it reads as text.
public enum SensorUnit: String, Sendable, Codable {
    case celsius
    case rpm
    case megahertz
    /// A share of time, 0...1, such as a cluster's active residency.
    case fraction
    case watts
    case volts
    case amperes

    public var symbol: String {
        switch self {
        case .celsius: "°C"
        case .rpm: "rpm"
        case .megahertz: "MHz"
        case .fraction: "%"
        case .watts: "W"
        case .volts: "V"
        case .amperes: "A"
        }
    }

    /// "41.6 °C", "1,350 rpm", "3.13 GHz", "16.9%", "412 mW", "27.87 V", "−520 mA".
    /// Power and current keep their sign: a battery reads negative while it discharges.
    public func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch self {
        case .celsius: return "\(Format.fixed(value, 1)) °C"
        case .rpm: return Format.rpm(value)
        case .megahertz: return Format.frequency(megahertz: value)
        case .fraction: return Format.percent(value, digits: 1)
        case .watts: return Self.signed(value, unit: "W", milli: "mW")
        case .volts: return "\(Format.fixed(value, abs(value) >= 100 ? 1 : 2)) V"
        case .amperes: return Self.signed(value, unit: "A", milli: "mA")
        }
    }

    private static func signed(_ value: Double, unit: String, milli: String) -> String {
        let magnitude = abs(value)
        if magnitude < 0.0005 { return "0 \(unit)" }
        let sign = value < 0 ? "\u{2212}" : ""
        if magnitude < 1 { return "\(sign)\(Int((magnitude * 1000).rounded())) \(milli)" }
        return "\(sign)\(Format.fixed(magnitude, magnitude >= 10 ? 1 : 2)) \(unit)"
    }
}

/// Where a reading comes from. None of these needs root.
public enum SensorSource: String, Sendable, Codable {
    /// The HID event system's temperature sensors.
    case hidSensor
    /// Read-only SMC keys.
    case smc
    /// IOReport's performance-state residency, with each state's clock from
    /// the device tree.
    case ioReport
    /// IOReport's energy counters.
    case ioReportEnergy
    /// The battery's gauge (`AppleSmartBattery`).
    case batteryGauge
    /// Worked out from other rows of the table, such as the hottest die.
    case derived

    public var title: String {
        switch self {
        case .hidSensor: "HID temperature sensor"
        case .smc: "SMC"
        case .ioReport: "IOReport residency and device-tree clocks"
        case .ioReportEnergy: "IOReport energy counters"
        case .batteryGauge: "Battery gauge"
        case .derived: "Worked out from the rows below it"
        }
    }

    /// A word or two for a group heading.
    public var shortTitle: String {
        switch self {
        case .hidSensor: "HID sensors"
        case .smc: "SMC"
        case .ioReport, .ioReportEnergy: "IOReport"
        case .batteryGauge: "Battery gauge"
        case .derived: "Derived"
        }
    }
}

/// One row of the sensor table: a temperature, fan speed, clock, active
/// share, power, voltage or current, with what it is and where it came from.
public struct SensorReading: Sendable, Codable, Identifiable, Hashable {
    /// Stable for the channel across samples, e.g. "temperature/PMU tdie3".
    public let id: String
    public let group: SensorGroup
    /// The row's place in its group. Rows of equal rank sort by label.
    public let rank: Int
    public let label: String
    public let unit: SensorUnit
    public let source: SensorSource
    /// The SMC key, HID sensor or IOReport channel behind the reading, when there's one.
    public let origin: String?
    /// nil when the channel exists but gave no reading this time: it's shown
    /// as "—" and left out of the lowest and highest, never counted as zero.
    public let value: Double?
    /// Why `value` is nil, such as "idle" or "unplugged".
    public let note: String?
    /// The span a range bar draws the reading on; nil for zero to the highest reading.
    public let scale: ClosedRange<Double>?

    public init(id: String, group: SensorGroup, rank: Int, label: String, unit: SensorUnit, source: SensorSource,
                origin: String? = nil, value: Double?, note: String? = nil, scale: ClosedRange<Double>? = nil) {
        self.id = id
        self.group = group
        self.rank = rank
        self.label = label
        self.unit = unit
        self.source = source
        self.origin = origin
        // A non-finite reading is no reading.
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
        self.note = self.value == nil ? note : nil
        self.scale = scale
    }

    /// The same row with no reading, for a channel that didn't report this time.
    func withoutValue(note: String) -> SensorReading {
        SensorReading(id: id, group: group, rank: rank, label: label, unit: unit, source: source,
                      origin: origin, value: nil, note: note, scale: scale)
    }

    /// Table order: by group, then rank, then label read naturally ("Die 2" before "Die 10").
    static func precedes(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
    }
}

extension ThermalState {
    /// 0 for nominal up to 3 for critical.
    public var severity: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public var title: String { rawValue.capitalized }
}
