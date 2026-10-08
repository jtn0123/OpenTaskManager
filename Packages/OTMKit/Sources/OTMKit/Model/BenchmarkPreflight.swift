import Foundation

/// A published sample, with its real interval so a pause never counts as quiet time.
public struct BenchmarkPreflightReading: Sendable, Codable, Equatable {
    public var date: Date
    public var interval: Double
    public var cpuBusy: Double?
    public var memoryPressure: MemoryPressure?
    public var thermal: ThermalState?
    public var power: BenchmarkPowerSource?
    public var lowPowerMode: Bool?

    public init(date: Date, interval: Double, cpuBusy: Double? = nil, memoryPressure: MemoryPressure? = nil,
                thermal: ThermalState? = nil, power: BenchmarkPowerSource? = nil, lowPowerMode: Bool? = nil) {
        self.date = date
        self.interval = interval
        self.cpuBusy = cpuBusy
        self.memoryPressure = memoryPressure
        self.thermal = thermal
        self.power = power
        self.lowPowerMode = lowPowerMode
    }

    public var quiet: Bool {
        guard interval.isFinite, interval > 0, interval <= 10,
              let cpuBusy, cpuBusy.isFinite, (0...0.1).contains(cpuBusy) else { return false }
        return memoryPressure == .normal && thermal == .nominal && power != nil && lowPowerMode != nil
    }
}

public struct BenchmarkPreflightRow: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var quiet: Bool
}

/// The conditions seen during a bounded wait, saved once with the session.
public struct BenchmarkPreflight: Sendable, Codable, Equatable {
    public var readings: [BenchmarkPreflightReading]
    public var rows: [BenchmarkPreflightRow]
    public var settled: Bool
    public var verdict: String
    public var elapsed: Double

    public init(readings: [BenchmarkPreflightReading], rows: [BenchmarkPreflightRow], settled: Bool, verdict: String, elapsed: Double) {
        self.readings = readings
        self.rows = rows
        self.settled = settled
        self.verdict = verdict
        self.elapsed = elapsed
    }
}

/// Watches only samples supplied by the caller. No clocks or system reads live here.
public struct BenchmarkSettling: Sendable {
    public static let defaultWindow = 30.0
    public static let maximumWait = 120.0
    /// Published samples land milliseconds off their nominal step; a hole this
    /// short belongs to the stretch, while a pause or a missed sample is a second or more.
    public static let jitter = 0.25
    public let window: Double
    public let started: Date
    public private(set) var readings: [BenchmarkPreflightReading] = []

    public init(started: Date, window: Double = defaultWindow) {
        self.started = started
        self.window = window.isFinite ? min(max(window, 1), Self.maximumWait) : Self.defaultWindow
    }

    public mutating func append(_ reading: BenchmarkPreflightReading) {
        guard reading.date >= started, reading.interval.isFinite, reading.interval > 0,
              reading.date > (readings.last?.date ?? .distantPast) else { return }
        readings.append(reading)
        // Keep a bounded record even if a sampler publishes faster than once a second.
        readings.removeAll { reading.date.timeIntervalSince($0.date) > Self.maximumWait }
        if readings.count > 1_000 { readings.removeFirst(readings.count - 1_000) }
    }

    public func snapshot(now: Date) -> BenchmarkPreflight {
        let elapsed = min(max(now.timeIntervalSince(started), 0), Self.maximumWait)
        let latest = readings.last(where: { $0.date <= now })
        let endDate = latest?.date ?? now
        let recent = readings.filter { endDate.timeIntervalSince($0.date) >= 0 && endDate.timeIntervalSince($0.date) < window }
        let last = recent.last
        let fresh = last.map { now.timeIntervalSince($0.date) <= min($0.interval * 2, 10) } ?? false
        var covered = 0.0
        var end = endDate
        var continuous = fresh
        for reading in recent.reversed() {
            let hole = end.timeIntervalSince(reading.date)
            if reading.interval > 10 || hole > Self.jitter { continuous = false }
            let lower = max(started, endDate.addingTimeInterval(-window), reading.date.addingTimeInterval(-reading.interval))
            covered += max((hole > Self.jitter ? reading.date : end).timeIntervalSince(lower), 0)
            end = min(end, lower)
        }
        let stablePower = recent.allSatisfy { $0.power == last?.power && $0.lowPowerMode == last?.lowPowerMode }
        let settled = continuous && covered >= window - Self.jitter && recent.allSatisfy(\.quiet) && stablePower
        let cpu = fresh ? last?.cpuBusy : nil
        let validCPU = cpu.map { $0.isFinite && (0...1).contains($0) } == true
        let cpuText = validCPU ? "CPU load \(Format.percent(cpu ?? 0)) now" : "CPU load unavailable"
        let cpuQuiet = validCPU && (cpu ?? 1) <= 0.1
        let memory = fresh ? last?.memoryPressure : nil
        let thermal = fresh ? last?.thermal : nil
        let power = fresh ? last?.power : nil
        let lowPower = fresh ? last?.lowPowerMode : nil
        let rows = [
            BenchmarkPreflightRow(id: "cpu", text: cpuText + (cpuQuiet ? " · quiet" : " · wait for load under 10%"), quiet: cpuQuiet),
            BenchmarkPreflightRow(id: "memory", text: "Memory pressure \(memory?.rawValue ?? "unavailable") · "
                + (memory == .normal ? "quiet" : "wait or proceed"), quiet: memory == .normal),
            BenchmarkPreflightRow(id: "thermal", text: "Thermal state \(thermal?.rawValue ?? "unavailable") · "
                + (thermal == .nominal ? "quiet" : "wait for nominal or proceed"), quiet: thermal == .nominal),
            BenchmarkPreflightRow(id: "power", text: Self.powerText(power), quiet: power == .ac),
            BenchmarkPreflightRow(id: "lowPower", text: Self.lowPowerText(lowPower), quiet: lowPower == false),
        ]
        let verdict = status(now: now).verdict(settled: settled, elapsed: elapsed, hasAdvisories: !rows.allSatisfy(\.quiet))
        return BenchmarkPreflight(readings: readings, rows: rows, settled: settled, verdict: verdict, elapsed: elapsed)
    }

    private static func lowPowerText(_ lowPower: Bool?) -> String {
        switch lowPower {
        case true: "Low Power Mode on · results may be lower · advisory only, does not delay readiness"
        case false: "Low Power Mode off · advisory only"
        case nil: "Low Power Mode unavailable · waiting for readings"
        }
    }

    private static func powerText(_ power: BenchmarkPowerSource?) -> String {
        switch power {
        case .battery: "On battery · results may be lower · advisory only, does not delay readiness"
        case .ac: "On power · quiet"
        case .ups: "On a UPS · advisory only, does not delay readiness"
        case nil: "Power source unavailable · review before proceeding"
        }
    }
}
