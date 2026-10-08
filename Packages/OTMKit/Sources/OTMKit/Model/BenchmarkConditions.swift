import Foundation

public extension BenchmarkComparison {
    /// A short account of warned differences, beside each verdict. Equal heat
    /// or load can still deserve a warning, but isn't a difference between runs.
    /// Keep two details here so it stays compact; the warning box carries all of them.
    static func conditionSummary(_ first: BenchmarkRun, _ second: BenchmarkRun) -> String? {
        let (earlier, later) = first.date <= second.date ? (first, second) : (second, first)
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
