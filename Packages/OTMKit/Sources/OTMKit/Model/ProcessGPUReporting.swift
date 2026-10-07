import Foundation

/// Decides, sample by sample, whether this Mac attributes GPU time to
/// processes, so a GPU column with nothing to show can start hidden.
///
/// Only "no process has any GPU time" counts against it. An idle GPU still
/// reports: every app that has drawn keeps its accumulated time, at 0% now.
/// A Mac whose GPU driver publishes no per-client time has none anywhere.
/// One process with GPU time settles it for the session; ruling it out takes
/// `samplesToRuleOut` samples in a row with none, so a GPU column doesn't
/// come and go as apps open and close their GPU connections.
public struct ProcessGPUReporting: Sendable, Equatable {
    /// Samples in a row with no GPU time anywhere before it counts as unreported.
    public static let samplesToRuleOut = 3

    /// nil until a sample (or the verdict kept from an earlier launch) has told.
    public private(set) var isReported: Bool?
    private var samplesWithout = 0
    private var seenThisSession = false

    /// `isReported` is the verdict kept from an earlier launch, if any.
    public init(isReported: Bool? = nil) {
        self.isReported = isReported
    }

    /// Takes one sample's processes: `anyGPUTime` when at least one had GPU
    /// time. Call only for samples that have a process list.
    public mutating func record(anyGPUTime: Bool) {
        if anyGPUTime {
            seenThisSession = true
            samplesWithout = 0
            isReported = true
        } else if !seenThisSession {
            samplesWithout += 1
            if samplesWithout >= Self.samplesToRuleOut { isReported = false }
        }
    }
}
