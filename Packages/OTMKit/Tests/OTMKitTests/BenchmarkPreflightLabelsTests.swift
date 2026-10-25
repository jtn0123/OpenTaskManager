import Foundation
@testable import OTMKit
import Testing

struct BenchmarkPreflightLabelsTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func reading(_ seconds: Double, cpu: Double = 0.03, thermal: ThermalState = .nominal,
                         pressure: MemoryPressure = .normal, power: BenchmarkPowerSource = .ac,
                         lowPower: Bool = false) -> BenchmarkPreflightReading {
        BenchmarkPreflightReading(date: start.addingTimeInterval(seconds), interval: 1, cpuBusy: cpu,
                                  memoryPressure: pressure, thermal: thermal, power: power, lowPowerMode: lowPower)
    }

    @Test func currentQuietStreakRestartsAfterHeatAndShowsTheDeadline() {
        var watch = BenchmarkSettling(started: start)
        for second in 1...30 {
            watch.append(reading(Double(second), thermal: second <= 18 ? .fair : .nominal))
        }
        let status = watch.status(now: start.addingTimeInterval(30))
        #expect(status.quietSeconds == 12)
        #expect(status.progress == "Quiet for 12 of 30 s · 90 s left before the 2-minute limit")
        #expect(watch.snapshot(now: start.addingTimeInterval(30)).verdict == "Waiting for 30 s of continuous quiet")
        for second in 31...48 { watch.append(reading(Double(second))) }
        #expect(watch.status(now: start.addingTimeInterval(48)).quietSeconds == 30)
        #expect(watch.snapshot(now: start.addingTimeInterval(48)).verdict == "Ready to proceed")
    }

    @Test func waitingNamesTheCurrentCondition() {
        let cases = [
            (reading(30, thermal: .fair), "Waiting for the thermal state to return to nominal"),
            (reading(30, cpu: 0.2), "Waiting for CPU load under 10%"),
            (reading(30, pressure: .warning), "Waiting for memory pressure to return to normal"),
        ]
        for (latest, message) in cases {
            var watch = BenchmarkSettling(started: start)
            for second in 1...29 { watch.append(reading(Double(second))) }
            watch.append(latest)
            #expect(watch.snapshot(now: latest.date).verdict == message)
            #expect(watch.status(now: latest.date).quietSeconds == 0)
        }
    }

    @Test func batteryAndLowPowerModeAreAdvisoriesButChangesNeedToSettle() {
        var watch = BenchmarkSettling(started: start)
        for second in 1...30 { watch.append(reading(Double(second), power: .battery, lowPower: true)) }
        let ready = watch.snapshot(now: start.addingTimeInterval(30))
        #expect(ready.settled)
        #expect(ready.verdict == "Ready to proceed · review the advisories")
        #expect(watch.status(now: start.addingTimeInterval(30)).quietSeconds == 30)
        for id in ["power", "lowPower"] {
            #expect(ready.rows.first { $0.id == id }?.text.contains("does not delay readiness") == true)
        }
        watch.append(reading(31))
        #expect(watch.snapshot(now: start.addingTimeInterval(31)).verdict == "Waiting for power readings to settle")
        #expect(watch.status(now: start.addingTimeInterval(31)).quietSeconds == 1)
    }

    @Test func missingStaleAndInterruptedSamplesCannotBorrowQuietTime() {
        var watch = BenchmarkSettling(started: start)
        for second in 1...30 where second != 18 { watch.append(reading(Double(second))) }
        #expect(watch.status(now: start.addingTimeInterval(30)).quietSeconds == 12)
        let stale = watch.status(now: start.addingTimeInterval(40))
        #expect(stale.quietSeconds == 0)
        #expect(stale.waiting == "Waiting for fresh, continuous samples")
        var missing = reading(41)
        missing.power = nil
        watch.append(missing)
        #expect(watch.snapshot(now: missing.date).verdict == "Waiting for power readings to settle")
        let limit = watch.snapshot(now: start.addingTimeInterval(150))
        #expect(limit.verdict == "Wait limit reached · proceed anyway or cancel")
        #expect(watch.status(now: start.addingTimeInterval(150)).remainingSeconds == 0)
    }

    @Test func jitterAndNonstandardWindowsMatchSettling() {
        var watch = BenchmarkSettling(started: start, window: 10)
        for index in 1...11 { watch.append(reading(Double(index) * 1.003)) }
        let now = start.addingTimeInterval(11.033)
        #expect(watch.snapshot(now: now).settled)
        #expect(watch.status(now: now).quietSeconds == 10)
        #expect(watch.status(now: now).progress.hasPrefix("Quiet for 10 of 10 s"))
    }
}
