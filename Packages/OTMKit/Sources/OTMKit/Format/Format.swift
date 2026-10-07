import Foundation

/// Compact, allocation-light formatters for values that refresh every tick.
public enum Format {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Binary-scaled sizes ("1.5 GB"), matching what Finder and Activity Monitor show for memory.
    public static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    public static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        var scaled = value
        var unit = 0
        while scaled >= 1024, unit < byteUnits.count - 1 {
            scaled /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(scaled)) B" }
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return "\(fixed(scaled, digits)) \(byteUnits[unit])"
    }

    public static func bytesPerSecond(_ value: Double) -> String {
        "\(bytes(value))/s"
    }

    /// Decimal bits per second ("12.4 Mbps"), the convention for network links.
    public static func bitsPerSecond(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        guard bits.isFinite, bits >= 0 else { return "—" }
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var scaled = bits
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        let digits = unit == 0 || scaled >= 100 ? 0 : 1
        return "\(fixed(scaled, digits)) \(units[unit])"
    }

    /// Formats a 0...1 fraction as a percentage.
    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        guard fraction.isFinite else { return "—" }
        return "\(fixed(fraction * 100, digits))%"
    }

    public static func watts(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value < 0.0005 { return "0 W" }
        if value < 1 { return "\(Int((value * 1000).rounded())) mW" }
        return "\(fixed(value, value >= 10 ? 1 : 2)) W"
    }

    /// "338 MHz", "4.51 GHz".
    public static func frequency(megahertz value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value.rounded() < 1000 { return "\(Int(value.rounded())) MHz" }
        return "\(fixed(value / 1000, 2)) GHz"
    }

    /// "3d 4h", "2h 05m", "4m 12s".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60, secs = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(pad(minutes))m" }
        if minutes > 0 { return "\(minutes)m \(pad(secs))s" }
        return "\(secs)s"
    }

    /// A graph's time span for its axis: "30 s", "5 min", "2 min 30 s", "1 h".
    public static func timeSpan(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let secs = total % 60
            return secs == 0 ? "\(total / 60) min" : "\(total / 60) min \(secs) s"
        }
        let minutes = total % 3600 / 60
        return minutes == 0 ? "\(total / 3600) h" : "\(total / 3600) h \(minutes) min"
    }

    /// CPU time as `h:mm:ss.cc`, the way `ps` and Activity Monitor show it.
    public static func cpuTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let hundredths = Int((seconds * 100).rounded())
        let hours = hundredths / 360_000
        let minutes = hundredths / 6000 % 60
        let secs = hundredths / 100 % 60
        let fraction = hundredths % 100
        let clock = "\(pad(minutes)):\(pad(secs)).\(pad(fraction))"
        return hours > 0 ? "\(hours):\(clock)" : clock
    }

    public static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(max(digits, 0))f", value)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
