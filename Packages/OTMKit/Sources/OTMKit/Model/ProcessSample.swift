import Foundation

public enum ProcessState: String, Sendable, Codable {
    case running, sleeping, idle, stopped, zombie, unknown
}

public struct ProcessSample: Sendable, Codable, Identifiable, Hashable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let parentPID: Int32
    /// The process macOS holds responsible for this one. Helpers, renderers
    /// and XPC services point at their app, which is how apps get grouped.
    public let responsiblePID: Int32
    public let uid: UInt32
    public let userName: String
    public let name: String
    public let executablePath: String?
    public var state: ProcessState
    public let nice: Int32
    public let startTime: Date?
    /// True when the process runs under Rosetta 2.
    public let isTranslated: Bool
    /// True when macOS refused detailed stats (another user's or a root
    /// process) and only the coarse `ps` view was available.
    public let isRestricted: Bool

    /// CPU use where 100 is one fully busy core, as in Activity Monitor and `top`.
    public var cpuPercent: Double
    /// Cumulative CPU time in seconds.
    public var cpuTime: Double
    /// Physical footprint: what Activity Monitor calls "Memory". Falls back to
    /// resident size for restricted processes.
    public var memory: UInt64
    public var residentMemory: UInt64
    public var threadCount: Int
    public var diskReadRate: Double
    public var diskWriteRate: Double
    public var diskReadTotal: UInt64
    public var diskWriteTotal: UInt64
    /// Average power over the last interval in watts (Apple silicon only).
    public var powerWatts: Double?
    /// Share of this process's recent CPU time spent on the fastest core tier.
    public var topTierShare: Double?
    public var wakeupsPerSecond: Double?
    /// GPU busy fraction attributed to this process, 0...1.
    public var gpuFraction: Double?
    /// Cumulative GPU time in seconds.
    public var gpuTime: Double?

    /// The enclosing `.app` bundle, derived from the executable path.
    public var bundlePath: String? {
        guard let path = executablePath, let range = path.range(of: "/Contents/MacOS/", options: .backwards) else {
            return nil
        }
        let bundle = String(path[..<range.lowerBound])
        return bundle.hasSuffix(".app") ? bundle : nil
    }

    public var isSystemProcess: Bool {
        uid == 0 || uid < 500 && uid != UInt32(getuid())
    }

    /// Whether processes sampled over `interval` show that this Mac counts
    /// energy per process: one power reading is enough, since our own
    /// processes always have one where the kernel counts energy. nil when the
    /// sample can't tell: no interval yet, or no process list.
    public static func measuresEnergy(_ processes: [ProcessSample], interval: TimeInterval) -> Bool? {
        guard interval > 0, !processes.isEmpty else { return nil }
        return processes.contains { $0.powerWatts != nil }
    }
}
