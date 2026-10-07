import Foundation
import os

/// One run of macOS's `networkQuality` tool: how much the connection carries
/// each way, and how responsive it stays while it's full.
public struct NetworkQualityResult: SpeedTestRecord, Equatable, Identifiable {
    public static let currentVersion = 1

    public var id: Date { date }
    public var version = Self.currentVersion
    /// When the run finished.
    public var date: Date
    /// The interface the run was bound to with `-I`; nil when the system
    /// picked the route.
    public var requestedInterface: String?
    /// The interface the tool says it used.
    public var interface: String?
    /// Capacity in bits per second; nil for a direction that wasn't tested.
    public var downloadBitsPerSecond: Double?
    public var uploadBitsPerSecond: Double?
    /// Round trips per minute on the loaded connection.
    public var responsiveness: Double?
    /// Round-trip time before the load, in milliseconds.
    public var idleLatency: Double?
    /// Bytes moved both ways, the test's traffic cost.
    public var bytesTransferred: UInt64?
    /// The server it measured against.
    public var endpoint: String?
    /// The tool's options as it reports them, and the macOS it shipped with.
    public var arguments: [String]
    public var toolVersion: String?
    /// Parallel connections each way.
    public var downloadFlows: Int?
    public var uploadFlows: Int?

    public init(date: Date, requestedInterface: String?, interface: String?, downloadBitsPerSecond: Double?,
                uploadBitsPerSecond: Double?, responsiveness: Double?, idleLatency: Double? = nil, bytesTransferred: UInt64? = nil,
                endpoint: String? = nil, arguments: [String] = [], toolVersion: String? = nil, downloadFlows: Int? = nil,
                uploadFlows: Int? = nil) {
        self.date = date
        self.requestedInterface = requestedInterface
        self.interface = interface
        self.downloadBitsPerSecond = downloadBitsPerSecond
        self.uploadBitsPerSecond = uploadBitsPerSecond
        self.responsiveness = responsiveness
        self.idleLatency = idleLatency
        self.bytesTransferred = bytesTransferred
        self.endpoint = endpoint
        self.arguments = arguments
        self.toolVersion = toolVersion
        self.downloadFlows = downloadFlows
        self.uploadFlows = uploadFlows
    }

    /// Results are kept per interface: the one used, else the one asked for.
    public var historyKey: String { interface ?? requestedInterface ?? "default" }

    public var rating: NetworkResponsiveness? { responsiveness.map(NetworkResponsiveness.init(rpm:)) }

    /// How the run was set up, in a few words: "en0 · parallel · 10 down, 14 up".
    public var configurationSummary: String {
        var parts = [requestedInterface.map { "bound to \($0)" } ?? "system route"]
        parts.append(arguments.contains("-s") ? "sequential" : "parallel")
        if let downloadFlows, let uploadFlows { parts.append("\(downloadFlows) down, \(uploadFlows) up") }
        return parts.joined(separator: " · ")
    }
}

/// Responsiveness in plain words. RPM is round trips a minute while the line
/// is full, so 60,000 / RPM is the delay a call or a click sees then.
public enum NetworkResponsiveness: Int, Sendable, Codable, CaseIterable, Comparable {
    case poor, fair, good, excellent

    public init(rpm: Double) {
        switch rpm {
        case 1000...: self = .excellent
        case 500..<1000: self = .good
        case 200..<500: self = .fair
        default: self = .poor
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .poor: "Poor"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    /// What it means for everyday use.
    public var summary: String {
        switch self {
        case .excellent: "Calls, games and browsing stay snappy even while the connection is busy."
        case .good: "Video calls and browsing hold up well while the connection is busy."
        case .fair: "Calls may stutter and pages lag while something else uses the connection."
        case .poor: "Expect lag and choppy calls whenever anything else uses the connection."
        }
    }

    /// The round trip implied by an RPM figure, in milliseconds.
    public static func loadedLatency(rpm: Double) -> Double? {
        rpm > 0 && rpm.isFinite ? 60_000 / rpm : nil
    }
}

public enum NetworkQualityError: Error, Equatable, Sendable {
    /// `/usr/bin/networkQuality` isn't on this Mac.
    case unavailable
    /// It ran past the time limit, or couldn't start.
    case didNotFinish
    case cancelled
    /// It ran but measured nothing; the tool's own reason when it gave one.
    case failed(String?)

    public var message: String {
        switch self {
        case .unavailable: "This Mac doesn't have the networkQuality tool (macOS 12 or later)."
        case .didNotFinish: "The test didn't finish in time. Check the connection and try again."
        case .cancelled: "The test was cancelled."
        case let .failed(reason): "The test couldn't measure the connection" + (reason.map { ": \($0)." } ?? ".")
        }
    }
}

/// Runs macOS's `networkQuality` and reads its machine-readable output (`-c`).
/// Only ever on request: the test deliberately fills the connection.
public enum NetworkQuality {
    public static let toolPath = "/usr/bin/networkQuality"
    /// About how long a run loads the connection.
    public static let typicalSeconds: TimeInterval = 20
    /// Longer than a slow link's run, short enough that a hung tool gives up.
    public static let timeout: TimeInterval = 90

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: toolPath) }

    /// `-c` for JSON, and `-I` to bind the run to one interface.
    public static func arguments(interface: String?) -> [String] {
        ["-c"] + (interface.map { ["-I", $0] } ?? [])
    }

    /// Whether the tool's usage text lists `-I`, which older releases lacked.
    public static func supportsInterfaceOption(usage: String) -> Bool {
        usage.range(of: #"(^|[\s\[])-I[\s:]"#, options: .regularExpression) != nil
    }

    private static let interfaceSupport = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Asks the tool once per run of the app.
    static func canBindInterface() async -> Bool {
        if let known = interfaceSupport.withLock({ $0 }) { return known }
        let usage = await CommandRunner.output(of: toolPath, ["-h"], timeout: 5) ?? ""
        let supported = supportsInterfaceOption(usage: usage)
        interfaceSupport.withLock { $0 = supported }
        return supported
    }

    /// Runs one test, bound to `interface` where the tool allows it.
    /// Cancelling the calling task stops the tool.
    public static func run(interface: String?) async throws(NetworkQualityError) -> NetworkQualityResult {
        guard isAvailable else { throw .unavailable }
        let bound = await canBindInterface() ? interface : nil
        let result = await CommandRunner.cancellableExecute(toolPath, arguments(interface: bound), capture: .output, timeout: timeout)
        if Task.isCancelled { throw .cancelled }
        guard let result else { throw .didNotFinish }
        return try parse(result.text, requestedInterface: bound, date: Date())
    }

    /// Reads the tool's JSON. Every field is optional, as releases differ;
    /// a run without a single measurement is a failure.
    public static func parse(_ output: String, requestedInterface: String?, date: Date) throws(NetworkQualityError) -> NetworkQualityResult {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any] else {
            throw .failed(nil)
        }
        func number(_ key: String) -> Double? {
            switch object[key] {
            case let value as NSNumber: value.doubleValue
            case let value as String: Double(value)
            default: nil
            }
        }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let result = NetworkQualityResult(
            date: date,
            requestedInterface: requestedInterface,
            interface: text("interface_name"),
            downloadBitsPerSecond: number("dl_throughput"),
            uploadBitsPerSecond: number("ul_throughput"),
            responsiveness: number("responsiveness"),
            idleLatency: number("base_rtt"),
            bytesTransferred: transferred(number("dl_bytes_transferred"), number("ul_bytes_transferred")),
            endpoint: text("test_endpoint"),
            arguments: object["cli_options"] as? [String] ?? [],
            toolVersion: text("os_version"),
            downloadFlows: number("dl_flows").map { Int($0) },
            uploadFlows: number("ul_flows").map { Int($0) }
        )
        let measured = [result.downloadBitsPerSecond, result.uploadBitsPerSecond, result.responsiveness]
            .contains { ($0 ?? 0) > 0 }
        guard measured else { throw .failed(failureReason(object)) }
        return result
    }

    private static func transferred(_ download: Double?, _ upload: Double?) -> UInt64? {
        guard download != nil || upload != nil else { return nil }
        return UInt64(max((download ?? 0) + (upload ?? 0), 0))
    }

    /// "NSURLErrorDomain -1009" from the error fields some releases write.
    private static func failureReason(_ object: [String: Any]) -> String? {
        let domain = object["error_domain"] as? String
        let code = (object["error_code"] as? NSNumber).map { String($0.intValue) }
        let parts = [domain, code].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
