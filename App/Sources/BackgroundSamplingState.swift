import AppKit
import OTMKit

/// Hidden ticks feed recording and a bounded system ring, never Observation.
/// Process graphs restart because their display-only figures weren't read.
@MainActor
final class BackgroundSamplingState {
    struct Point: Sendable {
        let snapshot: SystemSnapshot
        let sensors: SensorSample?
    }

    var points = History<Point>(capacity: AppModel.historyCapacity)
    var iconHistory = History<Double>(capacity: 14)
    var sensors: SensorSample?
    var readings: [SensorReading] = []
    var extremes = SensorExtremes(since: Date())
    var regularApps: [Int32: NSRunningApplication] = [:]
    var previousProcesses: [ProcessIdentity: ProcessSample] = [:]
    var wasHidden = false
    var hasGap = false
    var power = PowerEnergy()
    var peakWatts = 0.0
    var interval = 1.0

    func keep(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        wasHidden = true
        // A long tick after sleep cannot be drawn as one second of activity.
        if BackgroundGraphPolicy.isGap(interval: snapshot.interval, step: interval) {
            points.removeAll()
            hasGap = true
        }
        guard BackgroundGraphPolicy.keepsTick(interval: snapshot.interval, step: interval) else { return }
        points.append(Point(snapshot: snapshot.withoutProcesses(), sensors: sensors))
    }
}
