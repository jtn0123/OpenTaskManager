import Foundation
import Observation
import OTMKit

/// The label observes only the drawable result. Reading the whole snapshot
/// there invalidated the status item even when its cached image was unchanged.
@Observable
@MainActor
final class MenuBarIconStore {
    private(set) var drawing = MenuBarDrawing(history: [], usage: 0)
    @ObservationIgnored private var cadence = MenuBarDrawingCadence()

    func update(history: History<Double>, usage: Double, at time: TimeInterval) {
        if let changed = cadence.update(history: history.values, usage: usage, at: time) { drawing = changed }
    }
}
