import Foundation

/// The recorder's averages and CPU peak need system ticks, even without a
/// window, at the chosen speed but never faster than once a second, so a
/// hidden window never samples more often than a visible one. Its top-memory lists also need footprints at those ticks; CPU and
/// disk counters alone cannot recover a footprint that grew and shrank.
public struct BackgroundSamplingPolicy: Sendable, Equatable {
    public let interval: TimeInterval
    public let publishesViews: Bool
    public let processFigures: Bool
    public let processDetails: Bool
    public let processGPU: Bool
    public let restrictedProcessesLive: Bool
    public let sensorsLive: Bool
    public let recordsSpikes: Bool

    public init(visible: Bool, updateInterval: TimeInterval, recording: Bool, spikes: Bool,
                restrictedDemand: Bool = false, sensorDemand: Bool = false) {
        publishesViews = visible
        let chosen = spikes ? min(updateInterval, 1) : updateInterval
        interval = visible ? chosen : max(chosen, 1)
        processFigures = visible || recording || spikes
        processDetails = visible
        processGPU = visible
        restrictedProcessesLive = (visible && restrictedDemand) || spikes
        sensorsLive = visible && sensorDemand
        recordsSpikes = spikes
    }
}

/// Window demand is counted separately from source demand. A status item's
/// icon is not a window, and a locked or sleeping display cannot show one.
public struct SamplingVisibility: Sendable {
    public var applicationHidden = false
    public var displayAsleep = false
    public var screenLocked = false

    public init() {}

    public func isVisible(windowDemand: Bool) -> Bool {
        windowDemand && !applicationHidden && !displayAsleep && !screenLocked
    }
}

/// Live graphs have evenly spaced points. A retained tick can be replayed
/// only at its actual step; long stretches restart with the unrecorded look.
public enum BackgroundGraphPolicy {
    public static func canRestore(hiddenStep: TimeInterval, visibleStep: TimeInterval) -> Bool {
        hiddenStep == visibleStep
    }

    public static func isGap(interval: TimeInterval, step: TimeInterval) -> Bool {
        interval > step * 1.5
    }

    public static func keepsTick(interval: TimeInterval, step: TimeInterval) -> Bool {
        interval > 0 && !isGap(interval: interval, step: step)
    }
}
