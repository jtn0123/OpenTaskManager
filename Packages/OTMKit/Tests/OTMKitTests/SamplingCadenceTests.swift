import Foundation
@testable import OTMKit
import Testing

struct SamplingCadenceTests {
    @Test(arguments: [0.5, 1, 2, 5])
    func idleSourcesUseElapsedTimeAtEveryUpdateSpeed(step: Double) {
        var cadence = SamplingCadence()
        var times: [Double] = []
        for tick in 0...20 {
            let time = Double(tick) * step
            if cadence.shouldRead(at: time, live: false) { times.append(time) }
        }
        #expect(times.first == 0)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 5 && $1 - $0 < 5 + step })
    }

    @Test func rateSourcesPrimeBeforeHoldingTheirFirstMeasuredRate() {
        var cadence = SamplingCadence(primingReads: 2)
        var times: [Double] = []
        for second in 0...11 where cadence.shouldRead(at: Double(second), live: false) {
            times.append(Double(second))
        }
        #expect(times == [0, 1, 6, 11], "the first measured CPU rate arrives after one tick, not five")
    }

    @Test func enteringAndLeavingLiveDemandKeepsTheBaseline() {
        var cadence = SamplingCadence()
        let reads = [
            cadence.shouldRead(at: 100, live: false),
            cadence.shouldRead(at: 101, live: false),
            cadence.shouldRead(at: 102, live: true),
            cadence.shouldRead(at: 102.5, live: true),
            cadence.shouldRead(at: 103, live: false),
            cadence.shouldRead(at: 107.5, live: false),
            cadence.shouldRead(at: 200, live: false),
        ]
        #expect(reads == [true, false, true, true, false, true, true])
    }

    @Test func recorderCanRequireAReadWithoutHoldingLiveDemand() {
        var cadence = SamplingCadence()
        let reads = [
            cadence.shouldRead(at: 0, live: false),
            cadence.shouldRead(at: 3, live: false, required: true),
            cadence.shouldRead(at: 4, live: false),
            cadence.shouldRead(at: 8, live: false),
        ]
        #expect(reads == [true, true, false, true])
    }

    @Test func oneConsumerLeavingDoesNotReleaseAnotherWindowsDemand() {
        var demand = SamplingDemand()
        demand.add(.sensors)
        demand.add(.sensors)
        demand.add(.restrictedProcesses)
        demand.remove(.sensors)
        #expect(demand.contains(.sensors))
        demand.remove(.sensors)
        #expect(!demand.contains(.sensors))
        #expect(demand.contains(.restrictedProcesses))
        demand.remove(.sensors)
        demand.add(.sensors)
        #expect(demand.contains(.sensors), "an unmatched removal cannot create negative demand")
    }
}

struct RestrictedProcessCacheTests {
    private let identity = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 100))

    private func row(_ seconds: Double, memory: UInt64 = 1_000) -> PSReader.Row {
        PSReader.Row(cpuSeconds: seconds, residentBytes: memory, state: .running)
    }

    @Test func heldRowsKeepTheirCPUAndTheNextReadUsesItsRealInterval() throws {
        var cache = RestrictedProcessCache()
        cache.update(identity, row: row(10), threads: 2, at: 0)
        cache.update(identity, row: row(12.5), threads: 3, at: 5)
        let held = try #require(cache.reading(for: identity))
        #expect(held.cpuPercent == 50)
        // No read at seconds 6 through 9; even a failed attempt leaves the baseline alone.
        cache.update(identity, row: nil, threads: nil, at: 8)
        #expect(cache.reading(for: identity) == held)
        cache.update(identity, row: row(15, memory: 2_000), threads: nil, at: 10)
        let next = try #require(cache.reading(for: identity))
        #expect(next.cpuPercent == 50, "divide by five seconds, not the one-second app tick")
        #expect(next.residentBytes == 2_000 && next.threads == 3)
    }

    @Test func changingCadenceUsesTheTimeBetweenRealReads() {
        var cache = RestrictedProcessCache()
        cache.update(identity, row: row(10), threads: nil, at: 100)
        cache.update(identity, row: row(11), threads: nil, at: 102)
        #expect(cache.reading(for: identity)?.cpuPercent == 50)
        cache.update(identity, row: row(11.25), threads: nil, at: 102.5)
        #expect(cache.reading(for: identity)?.cpuPercent == 50)
        cache.update(identity, row: row(13.85), threads: nil, at: 107.7)
        #expect(abs((cache.reading(for: identity)?.cpuPercent ?? 0) - 50) < 1e-9)
    }

    @Test func reusedPIDsAndExitedProcessesDoNotInheritReadings() {
        var cache = RestrictedProcessCache()
        cache.update(identity, row: row(100), threads: 4, at: 0)
        let reused = ProcessIdentity(pid: identity.pid, startTime: Date(timeIntervalSince1970: 200))
        #expect(cache.reading(for: reused) == nil)
        cache.retain([reused])
        #expect(cache.reading(for: identity) == nil)
        cache.update(reused, row: row(1), threads: 1, at: 5)
        #expect(cache.reading(for: reused)?.cpuPercent == 0, "a new identity first takes a baseline")
    }

    @Test func counterResetNeverProducesANegativeRate() {
        var cache = RestrictedProcessCache()
        cache.update(identity, row: row(10), threads: nil, at: 0)
        cache.update(identity, row: row(1), threads: nil, at: 5)
        #expect(cache.reading(for: identity)?.cpuPercent == 0)
    }
}

struct MenuBarDrawingTests {
    @Test func comparesOnlyVisibleBarsAndRoundedText() {
        let first = MenuBarDrawing(history: Array(repeating: 0.2, count: 14), usage: 0.2)
        let subpixel = MenuBarDrawing(history: [1, 0] + Array(repeating: 0.205, count: 14), usage: 0.201)
        #expect(first == subpixel)
        #expect(first.heights == Array(repeating: 3, count: 14))
        #expect(first.text == "20%")
        #expect(first != MenuBarDrawing(history: Array(repeating: 0.3, count: 14), usage: 0.2))
        #expect(first != MenuBarDrawing(history: Array(repeating: 0.2, count: 14), usage: 0.21))
    }

    @Test func clampsBarsAndHandlesUnavailableFigures() {
        let drawing = MenuBarDrawing(history: [-1, 0, 1, 2, .nan], usage: .nan)
        #expect(drawing.heights == [1, 1, 14, 14, 1])
        #expect(drawing.text == "—")
    }

    @Test func publishesAtMostEveryTwoSecondsAndUsesTheNewestSample() {
        var cadence = MenuBarDrawingCadence()
        #expect(cadence.update(history: [0.1], usage: 0.1, at: 0)?.text == "10%")
        var evaluated = false
        func history() -> [Double] { evaluated = true; return [0.8] }
        #expect(cadence.update(history: history(), usage: 0.8, at: 1) == nil)
        #expect(!evaluated, "the icon does not even copy history on skipped ticks")
        #expect(cadence.update(history: [0.1, 0.8, 0.3], usage: 0.3, at: 2)?.text == "30%")
        #expect(cadence.update(history: [0.1, 0.8, 0.3], usage: 0.3, at: 4) == nil,
                "a due tick with identical pixels publishes nothing")
        #expect(cadence.update(history: [0.4], usage: 0.4, at: 5) == nil)
        #expect(cadence.update(history: [0.5], usage: 0.5, at: 6)?.text == "50%")
    }
}
