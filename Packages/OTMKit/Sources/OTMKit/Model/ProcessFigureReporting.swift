import Foundation

/// Decides, sample by sample, whether this Mac gives processes a figure (GPU
/// time, Neural Engine memory), so a column with nothing to show can start hidden.
///
/// Only "no process has any" counts against it. An idle GPU still reports:
/// every app that has drawn keeps its accumulated time, at 0% now. Neural
/// Engine memory likewise counts any process that has held some, even if it
/// holds none now. A Mac whose GPU driver publishes no per-client time, or
/// with no Neural Engine (a virtual machine), has none anywhere. One process
/// with the figure settles it for the session; ruling it out takes
/// `samplesToRuleOut` samples in a row with none, so a column doesn't come
/// and go as apps open and close their connections.
public struct ProcessFigureReporting: Sendable, Equatable {
    /// Samples in a row with no process having the figure before it counts as unreported.
    public static let samplesToRuleOut = 3

    /// nil until a sample (or the verdict kept from an earlier launch) has told.
    public private(set) var isReported: Bool?
    private var samplesWithout = 0
    private var seenThisSession = false

    /// `isReported` is the verdict kept from an earlier launch, if any.
    public init(isReported: Bool? = nil) {
        self.isReported = isReported
    }

    /// Takes one sample's processes: `anyProcess` when at least one had the
    /// figure. Call only for samples that have a process list.
    public mutating func record(anyProcess: Bool) {
        if anyProcess {
            seenThisSession = true
            samplesWithout = 0
            isReported = true
        } else if !seenThisSession {
            samplesWithout += 1
            if samplesWithout >= Self.samplesToRuleOut { isReported = false }
        }
    }
}
