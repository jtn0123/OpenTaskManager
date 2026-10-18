import OTMKit
import Testing

@MainActor
struct MiniMonitorStoreTests {
    private func figures(_ cpu: Double) -> MiniMonitorFigures {
        MiniMonitorFigures(cpu: cpu, memoryUsed: 1, memoryFraction: 0.5, pressure: .normal, gpu: nil,
                           networkIn: 0, networkOut: 0, diskRead: 0, diskWrite: 0, watts: nil)
    }

    @Test func offItKeepsNothing() {
        let store = MiniMonitorStore()
        store.add(figures(0.3), interval: 1, step: 1, publishes: true)
        #expect(store.reading == MiniMonitorReading())
    }

    @Test func itPublishesOnlyWhileShownAndCatchesUpWhenShownAgain() {
        let store = MiniMonitorStore()
        store.isOn = true
        store.add(figures(0.1), interval: 1, step: 1, publishes: true)
        #expect(store.reading.cpu == [0.1])
        store.add(figures(0.2), interval: 1, step: 1, publishes: false)
        store.add(figures(0.3), interval: 1, step: 1, publishes: false)
        #expect(store.reading.cpu == [0.1], "covered, it redraws nothing")
        store.add(figures(0.4), interval: 0.5, step: 1, publishes: true)
        #expect(store.reading.cpu == [0.1, 0.2, 0.3], "the steps it missed, published with the next tick")
        store.add(figures(0.6), interval: 0.5, step: 1, publishes: true)
        #expect(store.reading.cpu.count == 4)
        #expect(abs((store.reading.cpu.last ?? 0) - 0.5) < 1e-9)
    }

    @Test func turningItOffClearsItsGraphs() {
        let store = MiniMonitorStore()
        store.isOn = true
        store.add(figures(0.1), interval: 1, step: 1, publishes: true)
        store.isOn = false
        #expect(store.reading == MiniMonitorReading())
        store.isOn = true
        store.add(figures(0.2), interval: 1, step: 1, publishes: true)
        #expect(store.reading.cpu == [0.2])
    }
}
