import Foundation

/// Explains the current streak, rather than making a past busy reading look like a current load.
public struct BenchmarkPreflightStatus: Sendable, Equatable {
    public let quietSeconds: Double
    public let requiredSeconds: Double
    public let remainingSeconds: Double
    public let waiting: String

    public var progress: String {
        "Quiet for \(Int(quietSeconds)) of \(Int(requiredSeconds)) s · \(Int(remainingSeconds.rounded(.up))) s left before the 2-minute limit"
    }

    public func verdict(settled: Bool, elapsed: Double, hasAdvisories: Bool) -> String {
        if settled { return "Ready to proceed" + (hasAdvisories ? " · review the advisories" : "") }
        if elapsed >= BenchmarkSettling.maximumWait { return "Wait limit reached · proceed anyway or cancel" }
        return waiting
    }
}

extension BenchmarkSettling {
    /// The same sample intervals and jitter as settling; advisories never shorten a quiet streak.
    public func status(now: Date) -> BenchmarkPreflightStatus {
        let latest = readings.last(where: { $0.date <= now })
        let fresh = latest.map { now.timeIntervalSince($0.date) <= min($0.interval * 2, 10) } ?? false
        var quiet = 0.0
        if fresh, let latest {
            var end = latest.date
            for reading in readings.reversed() where reading.date <= latest.date {
                guard reading.quiet, reading.power == latest.power, reading.lowPowerMode == latest.lowPowerMode,
                      end.timeIntervalSince(reading.date) <= Self.jitter else { break }
                let lower = max(started, latest.date.addingTimeInterval(-window), reading.date.addingTimeInterval(-reading.interval))
                quiet += max(end.timeIntervalSince(lower), 0)
                end = min(end, lower)
                if quiet >= window - Self.jitter { quiet = window; break }
            }
        }
        let waiting: String
        if !fresh || (latest?.interval ?? 0) > 10 {
            waiting = "Waiting for fresh, continuous samples"
        } else if latest?.thermal != .nominal {
            waiting = "Waiting for the thermal state to return to nominal"
        } else if latest?.cpuBusy.map({ $0.isFinite && (0...0.1).contains($0) }) != true {
            waiting = latest?.cpuBusy == nil ? "Waiting for CPU load readings" : "Waiting for CPU load under 10%"
        } else if latest?.memoryPressure != .normal {
            waiting = "Waiting for memory pressure to return to normal"
        } else if latest?.power == nil || latest?.lowPowerMode == nil || readings.contains(where: {
            $0.date <= now && (latest?.date.timeIntervalSince($0.date) ?? .infinity) < window
                && ($0.power != latest?.power || $0.lowPowerMode != latest?.lowPowerMode)
        }) {
            waiting = "Waiting for power readings to settle"
        } else {
            waiting = "Waiting for \(Int(window)) s of continuous quiet"
        }
        return BenchmarkPreflightStatus(quietSeconds: quiet, requiredSeconds: window,
            remainingSeconds: max(Self.maximumWait - max(now.timeIntervalSince(started), 0), 0), waiting: waiting)
    }
}
