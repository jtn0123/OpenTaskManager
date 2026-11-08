import Testing
@testable import OTMKit

struct DockGraphTests {
    @Test func offDoesNotProduceADrawingAndSwitchingModesDropsOldValues() throws {
        var feed = DockGraphFeed()
        feed.add(cpu: 1, memory: 0.5, at: 0)
        #expect((feed.drawing(at: 0)) == nil)
        feed.setMode(.cpu)
        feed.add(cpu: 0.25, memory: 0.7, at: 0)
        let cpuValue = feed.drawing(at: 0)
        let cpu = try #require(cpuValue)
        #expect(cpu.percent == 25)
        feed.setMode(.memory)
        let pendingValue = feed.drawing(at: 0)
        let pending = try #require(pendingValue)
        #expect(pending.heights.isEmpty && pending.percent == nil && pending.mode == .memory)
        feed.add(cpu: 0.25, memory: 0.7, at: 2)
        let memoryValue = feed.drawing(at: 2)
        let memory = try #require(memoryValue)
        #expect(memory.percent == 70)
        feed.setMode(.off)
        #expect((feed.drawing(at: 4)) == nil)
    }

    @Test func rateLimitUsesLatestSamplesAndQuantizedPixels() throws {
        var feed = DockGraphFeed()
        feed.setMode(.cpu)
        feed.add(cpu: 0.1, memory: 0, at: 0)
        let initialValue = feed.drawing(at: 0)
        let initial = try #require(initialValue)
        #expect(initial.percent == 10)
        feed.add(cpu: 0.5, memory: 0, at: 1)
        #expect((feed.drawing(at: 1)) == nil)
        feed.add(cpu: 0.7, memory: 0, at: 2)
        let nextValue = feed.drawing(at: 2)
        let next = try #require(nextValue)
        #expect(next.percent == 70 && next.heights == [18, 25])
    }

    @Test func fullFlatHistoryStopsRedrawingAndKeepsTheCadence() {
        var feed = DockGraphFeed()
        feed.setMode(.cpu)
        for tick in 0..<60 {
            feed.add(cpu: 0.2, memory: 0, at: Double(tick * 2))
            _ = feed.drawing(at: Double(tick * 2))
        }
        feed.add(cpu: 0.201, memory: 0, at: 120)
        #expect((feed.drawing(at: 120)) == nil)
        feed.add(cpu: 0.9, memory: 0, at: 121)
        #expect((feed.drawing(at: 121)) == nil)
        #expect((feed.drawing(at: 122)?.percent) == 90)
    }

    @Test func gapsAndSlowerSamplingKeepRealTimeSlots() throws {
        var feed = DockGraphFeed()
        feed.setMode(.cpu)
        feed.add(cpu: 0.2, memory: 0, at: 0)
        feed.add(cpu: 0.8, memory: 0, at: 6)
        let gappedValue = feed.drawing(at: 6)
        let gapped = try #require(gappedValue)
        #expect(gapped.heights == [7, nil, nil, 29])
        feed.add(cpu: 0.4, memory: 0, at: 126)
        let expiredValue = feed.drawing(at: 126)
        let expired = try #require(expiredValue)
        #expect(expired.heights == [14])
    }

    @Test func pauseHoldsReadingsAndResumeLeavesAGap() throws {
        var feed = DockGraphFeed()
        feed.setMode(.memory)
        feed.add(cpu: 0, memory: 0.6, at: 0)
        _ = feed.drawing(at: 0)
        feed.setPaused(true)
        let pausedValue = feed.drawing(at: 1)
        let paused = try #require(pausedValue)
        #expect(paused.paused)
        feed.add(cpu: 0, memory: 0.9, at: 4)
        #expect((feed.drawing(at: 4)) == nil)
        feed.setPaused(false)
        feed.add(cpu: 0, memory: 0.5, at: 6)
        let resumedValue = feed.drawing(at: 6)
        let resumed = try #require(resumedValue)
        #expect(!resumed.paused && resumed.percent == 50 && resumed.heights == [22, nil, nil, 18])
    }

    @Test func hiddenDisplaySkipsDrawingButCatchesUpAndInputsAreClamped() throws {
        var feed = DockGraphFeed()
        feed.setMode(.cpu)
        feed.add(cpu: -1, memory: 0, at: 0)
        #expect((feed.drawing(at: 0, visible: false)) == nil)
        feed.add(cpu: 2, memory: 0, at: 2)
        let awakeValue = feed.drawing(at: 2)
        let awake = try #require(awakeValue)
        #expect(awake.percent == 100 && awake.heights == [0, 36])
        feed.add(cpu: .nan, memory: 0, at: 4)
        let missingValue = feed.drawing(at: 4)
        let missing = try #require(missingValue)
        #expect(missing.percent == nil)
        feed.add(cpu: 0.5, memory: 0, at: -2)
        let rewoundValue = feed.drawing(at: -2)
        let rewound = try #require(rewoundValue)
        #expect(rewound.heights == [18])
    }
}
