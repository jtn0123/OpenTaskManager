import Foundation

/// Each sensor's lowest and highest reading since a reset point, and the
/// mildest and worst thermal pressure. Only real readings count: a channel
/// with no value this time leaves its range alone rather than adding a zero.
/// Recording a tick is one dictionary update per channel, so it can run
/// every tick whether or not the table is on screen.
public struct SensorExtremes: Sendable {
    public struct Range: Sendable, Codable, Equatable {
        public private(set) var lowest: Double
        public private(set) var highest: Double
        /// Readings counted since the reset.
        public private(set) var samples: Int

        init(_ value: Double) {
            lowest = value
            highest = value
            samples = 1
        }

        mutating func add(_ value: Double) {
            lowest = min(lowest, value)
            highest = max(highest, value)
            samples += 1
        }
    }

    /// When the ranges started: launch, or the last reset.
    public private(set) var since: Date
    /// By `SensorReading.id`.
    public private(set) var ranges: [String: Range] = [:]
    public private(set) var mildestThermalState: ThermalState?
    public private(set) var worstThermalState: ThermalState?
    /// Ticks recorded since the reset.
    public private(set) var samples = 0
    /// The last reading of every channel seen since the reset, so a channel
    /// that stops reporting keeps its row and its range.
    private var channels: [String: SensorReading] = [:]

    public init(since: Date) {
        self.since = since
    }

    public subscript(id: String) -> Range? { ranges[id] }

    public mutating func record(_ readings: [SensorReading], thermalState: ThermalState?) {
        samples += 1
        for reading in readings {
            channels[reading.id] = reading
            guard let value = reading.value else { continue }
            if ranges[reading.id] == nil {
                ranges[reading.id] = Range(value)
            } else {
                ranges[reading.id]?.add(value)
            }
        }
        if let thermalState {
            if mildestThermalState.map({ thermalState.severity < $0.severity }) ?? true { mildestThermalState = thermalState }
            if worstThermalState.map({ thermalState.severity > $0.severity }) ?? true { worstThermalState = thermalState }
        }
    }

    /// Forgets every range and starts again from `date`.
    public mutating func reset(at date: Date) {
        since = date
        ranges = [:]
        channels = [:]
        mildestThermalState = nil
        worstThermalState = nil
        samples = 0
    }

    /// The table's rows: this tick's readings, plus any channel seen since
    /// the reset that didn't report this time, with no value, in its place.
    /// Call after `record` with the same readings.
    public func rows(_ readings: [SensorReading]) -> [SensorReading] {
        // `channels` holds every reading's ID, so equal counts mean none is missing.
        guard channels.count > readings.count else { return readings }
        let present = Set(readings.map(\.id))
        let missing = channels.values.filter { !present.contains($0.id) }.map { $0.withoutValue(note: "no reading") }
        return (readings + missing).sorted(by: SensorReading.precedes)
    }
}

/// `otm sensors --extremes`: what the sensors read over a stretch of time,
/// in the same shape the app's table shows.
public struct SensorExtremesReport: Sendable, Codable {
    public struct Row: Sendable, Codable {
        public let reading: SensorReading
        public let lowest: Double?
        public let highest: Double?
        /// Readings that counted toward the range.
        public let samples: Int
    }

    public struct Pressure: Sendable, Codable {
        public let now: ThermalState?
        public let mildest: ThermalState?
        public let worst: ThermalState?
    }

    public let since: Date
    public let until: Date
    /// Seconds between samples.
    public let interval: TimeInterval
    public let samples: Int
    public let thermalPressure: Pressure
    public let rows: [Row]
    /// The last raw temperatures, fans and rails.
    public let sensors: SensorSample?

    public init(extremes: SensorExtremes, rows: [SensorReading], thermalState: ThermalState?, until: Date,
                interval: TimeInterval, sensors: SensorSample?) {
        since = extremes.since
        self.until = until
        self.interval = interval
        samples = extremes.samples
        thermalPressure = Pressure(now: thermalState, mildest: extremes.mildestThermalState, worst: extremes.worstThermalState)
        self.rows = extremes.rows(rows).map { reading in
            let range = extremes[reading.id]
            return Row(reading: reading, lowest: range?.lowest, highest: range?.highest, samples: range?.samples ?? 0)
        }
        self.sensors = sensors
    }
}
