import Foundation
import Observation
import OTMKit

/// The mini monitor's readings. Fed every tick while it's on, so its graphs
/// are whole when it shows again, but published only while it's on screen:
/// one covered on the desktop, or under a sleeping display, redraws nothing.
@Observable
@MainActor
final class MiniMonitorStore {
    private(set) var reading = MiniMonitorReading()
    /// Whether the mini monitor is shown (`MiniMonitorController`). Off, it
    /// keeps nothing and costs nothing a tick.
    @ObservationIgnored var isOn = false {
        didSet {
            guard isOn != oldValue, !isOn else { return }
            feed = MiniMonitorFeed()
            unpublished = false
            reading = MiniMonitorReading()
        }
    }
    @ObservationIgnored private var feed = MiniMonitorFeed()
    /// A step finished while nothing showed it.
    @ObservationIgnored private var unpublished = false

    func add(_ figures: @autoclosure () -> MiniMonitorFigures, interval: TimeInterval, step: TimeInterval, publishes: Bool) {
        guard isOn else { return }
        if feed.add(figures(), interval: interval, step: step) { unpublished = true }
        guard publishes, unpublished else { return }
        reading = feed.reading
        unpublished = false
    }
}
