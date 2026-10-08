import Foundation

public extension BenchmarkComparison {
    /// A short account of warned differences, beside each verdict. Equal heat
    /// or load can still deserve a warning, but isn't a difference between runs.
    /// Keep two details here so it stays compact; the warning box carries all of them.
    static func conditionSummary(_ first: BenchmarkRun, _ second: BenchmarkRun) -> String? {
        let (earlier, later) = first.date <= second.date ? (first, second) : (second, first)
        let sessionDifferences = sessionWarnings(earlier, later)
        if !sessionDifferences.isEmpty { return sessionDifferences.prefix(2).map(\.text).joined(separator: "; ") }
        let warnings = contextWarnings(earlier, later)
        guard !warnings.isEmpty else { return nil }
        guard let one = earlier.context, let other = later.context else {
            return "\(earlier.context == nil ? "Earlier" : "Later") run context not recorded"
        }
        let topics = Set(warnings.map(\.topic))
        var parts: [String] = []
        if topics.contains(.power) {
            if one.power != other.power, let power = other.power {
                parts.append(power.phrase(hasBattery: other.hasBattery ?? one.hasBattery))
            }
            if one.lowPowerMode != other.lowPowerMode, let lowPower = other.lowPowerMode {
                parts.append("Low Power Mode \(lowPower ? "on" : "off")")
            }
        }
        if topics.contains(.cpuLoad), let busy = other.cpuLoad?.busy, let earlierBusy = one.cpuLoad?.busy,
           abs(busy - earlierBusy) >= BenchmarkContext.busyDifference {
            parts.append("\(Format.percent(busy)) CPU busy at start")
        }
        if topics.contains(.thermal), one.thermalAtStart != other.thermalAtStart, let thermal = other.thermalAtStart {
            parts.append("thermal \(thermal.rawValue) at start")
        }
        if topics.contains(.memory), let memory = other.availableMemoryBytes {
            parts.append("\(Format.bytes(memory)) memory available")
        }
        if topics.contains(.hardware) { parts.append("different hardware") }
        if topics.contains(.build) { parts.append("different app or build") }
        return parts.isEmpty ? nil : "Later run " + parts.prefix(2).joined(separator: ", ")
    }
}

public extension BenchmarkComparison {
    /// Describe different preflights without assigning a cause to the figures.
    static func sessionWarnings(_ earlier: BenchmarkRun, _ later: BenchmarkRun) -> [BenchmarkContextWarning] {
        guard let first = earlier.session, let second = later.session else { return [] }
        guard let one = first.preflight, let other = second.preflight else {
            return [BenchmarkContextWarning(topic: .notRecorded, text: "Session preflight not recorded in one or both sessions.")]
        }
        let before = one.readings.last
        let after = other.readings.last
        var warnings: [BenchmarkContextWarning] = []
        if before?.power != after?.power {
            func power(_ value: BenchmarkPowerSource?) -> String {
                switch value {
                case .ac: "on power"
                case .battery: "on battery"
                case .ups: "on a UPS"
                case nil: "with power source unavailable"
                }
            }
            warnings.append(BenchmarkContextWarning(topic: .power,
                text: "Session A started \(power(before?.power)); B \(power(after?.power))."))
        }
        if before?.lowPowerMode != after?.lowPowerMode {
            warnings.append(BenchmarkContextWarning(topic: .power, text: "The sessions started with different Low Power Mode readings."))
        }
        if before?.thermal != after?.thermal {
            warnings.append(BenchmarkContextWarning(topic: .thermal,
                text: "Session A started thermal \(before?.thermal?.rawValue ?? "unavailable"); B \(after?.thermal?.rawValue ?? "unavailable")."))
        }
        if before?.memoryPressure != after?.memoryPressure {
            warnings.append(BenchmarkContextWarning(topic: .memory, text: "The sessions started with different memory pressure readings."))
        }
        if one.rows.first(where: { $0.id == "cpu" }) != other.rows.first(where: { $0.id == "cpu" }) {
            warnings.append(BenchmarkContextWarning(topic: .cpuLoad, text: "The sessions observed different CPU loads in their preflights."))
        }
        if one.settled != other.settled {
            warnings.append(BenchmarkContextWarning(topic: .cpuLoad, text: "Only one session reached a quiet window before proceeding."))
        }
        return warnings
    }
}
