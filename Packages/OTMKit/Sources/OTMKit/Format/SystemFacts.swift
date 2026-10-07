import Foundation

/// Parsing and wording for the System page. Kept free of I/O so it can be tested.
public enum SystemFacts {
    // MARK: - Security tools

    /// Parses `csrutil status`: "System Integrity Protection status: enabled."
    /// A partly disabled SIP reports "unknown (Custom Configuration)".
    public static func parseSIP(_ output: String) -> SIPStatus? {
        guard let line = output.split(separator: "\n").first(where: { $0.lowercased().contains("status:") }),
              let colon = line.range(of: "status:", options: .caseInsensitive) else { return nil }
        let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        if value.contains("custom") { return .custom }
        if value.hasPrefix("enabled") { return .enabled }
        if value.hasPrefix("disabled") { return .disabled }
        return nil
    }

    /// Parses `fdesetup status`, which needs no administrator rights.
    public static func parseFileVault(_ output: String) -> FileVaultStatus? {
        let text = output.lowercased()
        if text.contains("encryption in progress") { return .encrypting(percentComplete(output)) }
        if text.contains("decryption in progress") { return .decrypting(percentComplete(output)) }
        if text.contains("filevault is on") { return .on }
        if text.contains("filevault is off") {
            return text.contains("after the next restart") ? .pendingRestart : .off
        }
        return nil
    }

    /// Parses `spctl --status`: "assessments enabled" or "assessments disabled".
    public static func parseGatekeeper(_ output: String) -> GatekeeperStatus? {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .enabled }
        if text.contains("assessments disabled") { return .disabled }
        return nil
    }

    /// "Percent completed = 34.2" → 34.2.
    private static func percentComplete(_ output: String) -> Double? {
        guard let equals = output.range(of: "=", options: .backwards) else { return nil }
        let digits = output[equals.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    // MARK: - Kernel

    /// Splits `kern.version`, such as
    /// "Darwin Kernel Version 27.2.0: Tue Sep 29 21:48:08 PDT 2026; root:xnu-13432.40.177.0.3~56/RELEASE_ARM64_T6050".
    public static func parseKernelVersion(_ text: String) -> KernelVersion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = trimmed.split(separator: ";", maxSplits: 1).first.map(String.init) ?? trimmed
        var release: String?
        var date: String?
        if let colon = head.firstIndex(of: ":") {
            let name = head[..<colon]
            release = name.split(separator: " ").last.map(String.init)
            date = head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var xnu: String?
        var configuration: String?
        if let root = trimmed.range(of: "root:") {
            let parts = trimmed[root.upperBound...].split(separator: "/", maxSplits: 1)
            xnu = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
            configuration = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        }
        return KernelVersion(release: release, buildDate: date.flatMap { $0.isEmpty ? nil : $0 }, xnu: xnu,
                             configuration: configuration)
    }

    // MARK: - Battery

    /// macOS's own verdict when the power source reports one, else an
    /// estimate from capacity: below 80% of design is when Apple recommends service.
    public static func batteryCondition(health: String?, healthCondition: String?, capacity: Double?) -> BatteryCondition? {
        if let condition = healthCondition?.trimmingCharacters(in: .whitespaces), !condition.isEmpty {
            let summary = switch condition.lowercased() {
            case "check battery": "Service recommended"
            case "permanent battery failure": "Permanent failure"
            default: condition
            }
            return BatteryCondition(summary: summary, isEstimated: false)
        }
        switch health?.lowercased() {
        case "good": return BatteryCondition(summary: "Normal", isEstimated: false)
        case "fair", "poor", "check battery": return BatteryCondition(summary: "Service recommended", isEstimated: false)
        default: break
        }
        guard let capacity, capacity.isFinite, capacity > 0 else { return nil }
        return BatteryCondition(summary: capacity < 0.8 ? "Service recommended" : "Normal", isEstimated: true)
    }

    // MARK: - Formatting

    /// Installed memory the way it's sold: "48 GB", "16 GB". Odd sizes fall back to `Format.bytes`.
    public static func memorySize(_ bytes: UInt64) -> String {
        let gibibyte: UInt64 = 1 << 30
        if bytes >= gibibyte, bytes % gibibyte == 0 { return "\(bytes / gibibyte) GB" }
        return Format.bytes(bytes)
    }

    /// Drive and volume capacity in decimal units, as printed on the box and
    /// shown by Finder: "2 TB", "494 GB", "1.5 TB".
    public static func decimalBytes(_ bytes: UInt64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) bytes" }
        let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
        return "\(trimmed(value, digits)) \(units[unit])"
    }

    /// "27.2", or "27.2.1" when there's a patch release.
    public static func productVersion(major: Int, minor: Int, patch: Int) -> String {
        patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }

    /// "120 Hz", "59.94 Hz".
    public static func refreshRate(_ hertz: Double) -> String {
        "\(trimmed(hertz, 2)) Hz"
    }

    /// "3456 × 2234".
    public static func resolution(_ display: DisplayInfo) -> String {
        "\(display.pixelWidth) × \(display.pixelHeight)"
    }

    /// "3456 × 2234 (looks like 1728 × 1117) · 120 Hz".
    public static func describe(_ display: DisplayInfo) -> String {
        var text = resolution(display)
        if display.pointWidth != display.pixelWidth || display.pointHeight != display.pixelHeight {
            text += " (looks like \(display.pointWidth) × \(display.pointHeight))"
        }
        if let rate = display.refreshRate, rate > 0 { text += " · " + refreshRate(rate) }
        return text
    }

    /// "18 cores: 6 Super, 12 Performance". A single tier is just "8 cores".
    public static func coreSummary(_ topology: CPUTopology) -> String {
        let total = "\(topology.physicalCores) cores"
        guard topology.tiers.count > 1 else { return total }
        return total + ": " + topology.tiers.map { "\($0.physicalCPUs) \($0.name)" }.joined(separator: ", ")
    }

    /// "a4:83:e7:0b:12:9c"; nil for an all-zero or empty address.
    public static func hardwareAddress(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined(separator: ":")
    }

    /// Fixed digits with trailing zeros (and a bare point) removed.
    private static func trimmed(_ value: Double, _ digits: Int) -> String {
        var text = Format.fixed(value, digits)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

public extension SIPStatus {
    var summary: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .custom: "Partly disabled (custom configuration)"
        }
    }

    var isProtected: Bool { self == .enabled }
}

public extension FileVaultStatus {
    var summary: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .pendingRestart: "Turns on at the next restart"
        case let .encrypting(percent): "Encrypting" + (percent.map { " (\(Format.fixed($0, 0))% done)" } ?? "")
        case let .decrypting(percent): "Decrypting" + (percent.map { " (\(Format.fixed($0, 0))% done)" } ?? "")
        }
    }

    var isProtected: Bool {
        switch self {
        case .on, .encrypting: true
        case .off, .pendingRestart, .decrypting: false
        }
    }
}

public extension GatekeeperStatus {
    var summary: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        }
    }

    var isProtected: Bool { self == .enabled }
}
