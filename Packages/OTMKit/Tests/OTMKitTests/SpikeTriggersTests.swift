import Foundation
@testable import OTMKit
import Testing

private let mebibyte = 1_048_576.0

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_369_600 + seconds) }

private func sample(_ seconds: Double, cpu: Double = 0.1, interval: Double = 1, disk: Double = 0, network: Double = 0,
                    pressure: MemoryPressure = .normal, thermal: ThermalState = .nominal) -> SpikeSample {
    var sample = SpikeSample(time: date(seconds), interval: interval)
    sample.cpu = cpu
    sample.diskRead = disk / 2
    sample.diskWrite = disk / 2
    sample.networkIn = network
    sample.pressure = pressure
    sample.memoryPressure = pressure == .normal ? 0.3 : 0.8
    sample.thermal = thermal
    return sample
}

/// Feeds one update a second, the first ending at `from`, and returns every trigger.
private func feed(_ triggers: inout SpikeTriggers, from: Double, _ samples: [(Double) -> SpikeSample]) -> [SpikeTrigger] {
    samples.enumerated().flatMap { offset, make in triggers.update(make(from + Double(offset))) }
}

private func repeated(_ count: Int, _ make: @escaping (Double) -> SpikeSample) -> [(Double) -> SpikeSample] {
    Array(repeating: make, count: count)
}

struct SpikeTriggersTests {
    // MARK: CPU

    @Test func cpuTriggersOnceTheWholeCPUHasBeenBusyForTenSeconds() throws {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(30, { sample($0) })).isEmpty)
        #expect(feed(&triggers, from: 31, repeated(9, { sample($0, cpu: 0.9) })).isEmpty)
        #expect(triggers.isActive(.cpu))
        let fired = triggers.update(sample(40, cpu: 0.9))
        let trigger = try #require(fired.first)
        #expect(fired.count == 1)
        #expect(trigger.kind == .cpu)
        #expect(trigger.time == date(40))
        #expect(trigger.since == date(30))
        #expect(abs(trigger.figure - 0.9) < 1e-9)
        #expect(trigger.threshold == 0.8)
        #expect(trigger.summary == "90% of the whole CPU for 10 s")
    }

    @Test func aShortBurstOfCPUDoesntTrigger() {
        var triggers = SpikeTriggers()
        let burst = repeated(9, { sample($0, cpu: 0.99) }) + repeated(5, { sample($0, cpu: 0.2) })
        #expect(feed(&triggers, from: 1, burst + burst + burst).isEmpty)
        #expect(!triggers.isActive(.cpu))
    }

    @Test func aDipAboveTheReleaseCarriesTheStretchOn() {
        var triggers = SpikeTriggers()
        let wavering = (0..<10).map { index in { (time: Double) in sample(time, cpu: index == 4 ? 0.75 : 0.9) } }
        let fired = feed(&triggers, from: 1, wavering)
        #expect(fired.map(\.kind) == [.cpu])
        #expect(fired.first?.since == date(0))
    }

    @Test func aDipUnderTheReleaseStartsAgain() {
        var triggers = SpikeTriggers()
        let broken = repeated(6, { sample($0, cpu: 0.95) }) + [{ sample($0, cpu: 0.6) }] + repeated(9, { sample($0, cpu: 0.95) })
        #expect(feed(&triggers, from: 1, broken).isEmpty)
        let fired = triggers.update(sample(17, cpu: 0.95))
        #expect(fired.first?.since == date(7))
    }

    @Test func aStretchMustAverageTheThresholdNotJustStayOverTheRelease() {
        var triggers = SpikeTriggers()
        // Starts at 80%, then sits at 72%: a stretch, but never a busy one.
        let fired = feed(&triggers, from: 1, [{ sample($0, cpu: 0.8) }] + repeated(60, { sample($0, cpu: 0.72) }))
        #expect(fired.isEmpty)
        #expect(triggers.isActive(.cpu))
    }

    @Test func oneLongStretchTriggersOnce() {
        var triggers = SpikeTriggers()
        // Longer than the cooldown: still one incident until it ends.
        #expect(feed(&triggers, from: 1, repeated(900, { sample($0, cpu: 0.95) })).count == 1)
    }

    @Test func cpuCoolsDownBeforeTriggeringAgain() {
        var triggers = SpikeTriggers()
        let busy = repeated(20, { sample($0, cpu: 0.95) })
        let quiet = repeated(10, { sample($0, cpu: 0.1) })
        #expect(feed(&triggers, from: 1, busy).map(\.time) == [date(10)])
        // Back within ten minutes: the same incident as far as captures go.
        #expect(feed(&triggers, from: 21, quiet + busy).isEmpty)
        #expect(feed(&triggers, from: 51, repeated(560, { sample($0, cpu: 0.1) })).isEmpty)
        // Ten minutes after the first trigger it can fire again.
        #expect(feed(&triggers, from: 611, busy).map(\.time) == [date(620)])
    }

    // MARK: Memory and thermal pressure

    @Test func memoryPressureTriggersOnTheUpdateThatRaisesIt() throws {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(4, { sample($0) })).isEmpty)
        let fired = triggers.update(sample(5, pressure: .warning))
        let trigger = try #require(fired.first)
        #expect(trigger.kind == .memory)
        #expect(trigger.level == "warning")
        #expect(trigger.since == date(4))
        #expect(trigger.figure == 0.8)
        #expect(trigger.summary == "reached warning")
        // Going on to critical is the same incident.
        #expect(feed(&triggers, from: 6, repeated(30, { sample($0, pressure: .critical) })).isEmpty)
        #expect(triggers.isActive(.memory))
        // Back to normal and up again within the cooldown: nothing.
        #expect(feed(&triggers, from: 36, [{ sample($0) }, { sample($0, pressure: .warning) }]).isEmpty)
        #expect(feed(&triggers, from: 38, repeated(600, { sample($0) })).isEmpty)
        #expect(!triggers.isActive(.memory))
        #expect(triggers.update(sample(638, pressure: .critical)).map(\.level) == ["critical"])
    }

    @Test func thermalPressureTriggersAtSeriousNotFair() {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(20, { sample($0, thermal: .fair) })).isEmpty)
        #expect(!triggers.isActive(.thermal))
        let fired = triggers.update(sample(21, thermal: .serious))
        #expect(fired.map(\.kind) == [.thermal])
        #expect(fired.first?.level == "serious")
        #expect(fired.first?.figure == 2)
        #expect(triggers.update(sample(22, thermal: .critical)).isEmpty)
    }

    // MARK: Disk and network bursts

    @Test func aDiskBurstWellAboveItsUsualRateTriggers() throws {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(120, { sample($0, disk: 2 * mebibyte) })).isEmpty)
        #expect(feed(&triggers, from: 121, repeated(9, { sample($0, disk: 200 * mebibyte) })).isEmpty)
        let trigger = try #require(triggers.update(sample(130, disk: 200 * mebibyte)).first)
        #expect(trigger.kind == .disk)
        #expect(trigger.since == date(120))
        #expect(trigger.figure == 200 * mebibyte)
        #expect(trigger.threshold == 64 * mebibyte)
        #expect(abs((trigger.baseline ?? 0) - 2 * mebibyte) < 1)
        #expect(trigger.summary == "\(Format.bytesPerSecond(200 * mebibyte)) for 10 s, usually \(Format.bytesPerSecond(2 * mebibyte))")
    }

    @Test func aBurstUnderTheFloorNeverCounts() {
        var triggers = SpikeTriggers()
        // A hundred times an idle Mac's usual rate, but still under 64 MB/s.
        let fired = feed(&triggers, from: 1, repeated(120, { sample($0, disk: 0.3 * mebibyte) })
                         + repeated(60, { sample($0, disk: 30 * mebibyte) }))
        #expect(fired.isEmpty)
    }

    @Test func aBurstIsMeasuredAgainstTheUsualRate() {
        var triggers = SpikeTriggers()
        // Usually 50 MB/s: 120 MB/s is under four times that, 250 MB/s over it.
        #expect(feed(&triggers, from: 1, repeated(300, { sample($0, disk: 50 * mebibyte) })
                     + repeated(30, { sample($0, disk: 120 * mebibyte) })).isEmpty)
        let fired = feed(&triggers, from: 331, repeated(10, { sample($0, disk: 250 * mebibyte) }))
        #expect(fired.map(\.kind) == [.disk])
        #expect((fired.first?.threshold ?? 0) > 64 * mebibyte)
    }

    @Test func nothingCountsBeforeTheUsualRateHasWarmedUp() {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(30, { sample($0, disk: 500 * mebibyte) })).isEmpty)
    }

    @Test func theUsualRateStandsStillDuringABurst() throws {
        var thresholds = SpikeThresholds()
        thresholds.cooldown = 30
        var triggers = SpikeTriggers(thresholds: thresholds)
        let quiet = repeated(120, { sample($0, network: mebibyte) })
        let burst = repeated(100, { sample($0, network: 100 * mebibyte) })
        #expect(feed(&triggers, from: 1, quiet + burst).map(\.kind) == [.network])
        let second = feed(&triggers, from: 221, repeated(5, { sample($0, network: mebibyte) }) + burst)
        let trigger = try #require(second.first)
        #expect(trigger.kind == .network)
        // A hundred seconds of 100 MB/s didn't teach it that 100 MB/s is usual.
        #expect(abs((trigger.baseline ?? 0) - mebibyte) < 1)
        #expect(trigger.threshold == 8 * mebibyte)
    }

    // MARK: Pauses

    @Test func aPauseEndsEveryStretch() throws {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(8, { sample($0, cpu: 0.95) })).isEmpty)
        // Thirty seconds without an update (paused, or asleep).
        #expect(triggers.update(sample(38, cpu: 0.95)).isEmpty)
        #expect(!triggers.isActive(.cpu))
        #expect(feed(&triggers, from: 39, repeated(9, { sample($0, cpu: 0.95) })).isEmpty)
        let trigger = try #require(triggers.update(sample(48, cpu: 0.95)).first)
        #expect(trigger.since == date(38))
    }

    @Test func anUpdateCoveringAPauseCountsInNoStretch() {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(5, { sample($0, cpu: 0.95) })).isEmpty)
        #expect(triggers.update(sample(25, cpu: 0.95, interval: 20)).isEmpty)
        #expect(!triggers.isActive(.cpu))
    }

    @Test func pressureStillTriggersOnTheFirstUpdateAfterAPause() {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 1, repeated(5, { sample($0) })).isEmpty)
        #expect(triggers.update(sample(500, pressure: .critical)).map(\.kind) == [.memory])
    }

    @Test func theClockGoingBackwardsEndsEveryStretch() {
        var triggers = SpikeTriggers()
        #expect(feed(&triggers, from: 100, repeated(8, { sample($0, cpu: 0.95) })).isEmpty)
        #expect(triggers.update(sample(50, cpu: 0.95)).isEmpty)
        #expect(!triggers.isActive(.cpu))
    }

    // MARK: Forcing

    @Test func aForcedTriggerCountsLikeAnyOther() {
        var triggers = SpikeTriggers()
        let forced = triggers.force(.cpu, on: sample(10, cpu: 0.12))
        #expect(forced.kind == .cpu)
        #expect(forced.figure == 0.12)
        #expect(forced.since == date(9))
        // The kind cools down after it.
        #expect(feed(&triggers, from: 11, repeated(30, { sample($0, cpu: 0.95) })).isEmpty)
        // A forced pressure trigger names a level that would have triggered.
        #expect(triggers.force(.memory, on: sample(50)).level == "warning")
        #expect(triggers.force(.thermal, on: sample(51, thermal: .critical)).figure == 3)
        #expect(triggers.force(.thermal, on: sample(52, thermal: .critical)).level == "critical")
        #expect(triggers.force(.thermal, on: sample(53)).level == "serious")
    }
}
