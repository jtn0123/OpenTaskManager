/// How per-process CPU is shown. macOS tools count 100% per core, so a busy
/// app on an 18-core Mac can read 1,200%; the default is share of the whole CPU.
public struct CPUScale: Equatable, Sendable {
    public var relativeToSystem: Bool
    public var logicalCores: Int

    public init(relativeToSystem: Bool, logicalCores: Int) {
        self.relativeToSystem = relativeToSystem
        self.logicalCores = logicalCores
    }

    /// Converts a per-process figure (100 = one core) to the chosen scale.
    public func value(_ percentOfCore: Double) -> Double {
        guard relativeToSystem else { return percentOfCore }
        return min(percentOfCore / Double(max(logicalCores, 1)), 100)
    }

    public func format(_ percentOfCore: Double) -> String {
        Format.fixed(value(percentOfCore), 1) + "%"
    }

    /// One shown step (0.1%) in per-core percent, so sorts compare CPU as it
    /// reads and rows that read the same don't trade places every tick.
    public var shownStep: Double {
        relativeToSystem ? 0.1 * Double(max(logicalCores, 1)) : 0.1
    }
}
