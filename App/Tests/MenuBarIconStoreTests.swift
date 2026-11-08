import Observation
import os
import OTMKit
import Testing

@MainActor
struct MenuBarIconStoreTests {
    @Test func firstReadingPublishesAndSkippedTicksKeepThePreviousDrawing() {
        let store = MenuBarIconStore()
        #expect(store.drawing == MenuBarDrawing(history: [], usage: 0))
        var history = History<Double>(capacity: 30)
        history.append(0.1)
        store.update(history: history, usage: 0.1, at: 100)
        #expect(store.drawing.text == "10%")
        let first = store.drawing
        history.append(0.8)
        store.update(history: history, usage: 0.8, at: 101)
        #expect(store.drawing == first)
        history.append(0.3)
        store.update(history: history, usage: 0.3, at: 102)
        #expect(store.drawing == MenuBarDrawing(history: [0.1, 0.8, 0.3], usage: 0.3))
    }

    @Test func identicalPixelsNeverInvalidateTheLabelAndStillAdvanceCadence() {
        let store = MenuBarIconStore()
        var history = History<Double>(capacity: 30)
        for _ in 0..<14 { history.append(0.2) }
        store.update(history: history, usage: 0.2, at: 0)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.drawing
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        history.append(0.205)
        store.update(history: history, usage: 0.201, at: 2)
        #expect(changes.withLock { $0 } == 0)
        history.append(0.7)
        store.update(history: history, usage: 0.7, at: 3)
        #expect(changes.withLock { $0 } == 0)
        store.update(history: history, usage: 0.7, at: 4)
        #expect(changes.withLock { $0 } == 1)
        #expect(store.drawing.text == "70%")
    }

    @Test(arguments: [2.0, 5.0])
    func slowerSamplingPublishesTheNewestConsecutiveBars(step: Double) {
        let store = MenuBarIconStore()
        var history = History<Double>(capacity: 30)
        for tick in 0..<20 {
            let usage = Double(tick) / 20
            history.append(usage)
            store.update(history: history, usage: usage, at: Double(tick) * step)
        }
        #expect(store.drawing == MenuBarDrawing(history: (6..<20).map { Double($0) / 20 }, usage: 0.95))
        #expect(store.drawing.heights.count == 14)
    }
}
