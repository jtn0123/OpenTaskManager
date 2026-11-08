import Foundation
@testable import OTMKit
import Testing

struct SpikeReplayTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_369_600 + seconds) }

    private func trigger(_ seconds: Double, kind: SpikeKind = .cpu) -> SpikeTrigger {
        SpikeTrigger(kind: kind, time: date(seconds), since: date(seconds - 10), figure: 0.9, threshold: 0.8)
    }

    private func incident(_ triggers: [SpikeTrigger]) -> SpikeIncident {
        SpikeIncident(triggers: triggers, start: date(20), end: date(80), ongoing: false, average: 0.9, peak: 1)
    }

    @Test func opensAtTheFirstTriggerRatherThanTheConditionStartOrCaptureEnd() {
        let capture = incident([trigger(30), trigger(50, kind: .memory)])
        #expect(SpikeReplay.openingMoment(incident: capture) == date(30))
        #expect(SpikeReplay.openingMoment(incident: capture) != capture.start)
        #expect(SpikeReplay.openingMoment(incident: nil) == nil)
    }

    @Test func placesAllTriggersInTheChartsTimeRange() {
        let capture = incident([trigger(10), trigger(30, kind: .memory), trigger(90, kind: .disk)])
        let markers = SpikeReplay.markers(incident: capture, within: date(10)...date(50))
        #expect(markers.map(\.trigger) == Array(capture.triggers.prefix(2)))
        #expect(markers.map(\.fraction) == [0, 0.5])
        let whole = SpikeReplay.markers(incident: capture, within: date(10)...date(90))
        #expect(whole.map(\.fraction) == [0, 0.25, 1])
    }

    @Test func retainsSimultaneousTriggersAndSubsecondTimes() {
        let capture = incident([trigger(30.25), trigger(30.25, kind: .thermal)])
        let markers = SpikeReplay.markers(incident: capture, within: date(30)...date(31))
        #expect(markers.map(\.fraction) == [0.25, 0.25])
        #expect(markers.map(\.trigger.kind) == [.cpu, .thermal])
        #expect(SpikeReplay.openingMoment(incident: capture) == date(30.25))
    }

    @Test func hasNoMarkersForOrdinaryRecordingsOrAnEmptyTimeRange() {
        #expect(SpikeReplay.markers(incident: nil, within: date(0)...date(100)).isEmpty)
        #expect(SpikeReplay.markers(incident: incident([trigger(30)]), within: date(30)...date(30)).isEmpty)
        #expect(SpikeReplay.markers(incident: incident([trigger(30)]), within: date(40)...date(60)).isEmpty)
    }

    @Test func aSavedCaptureOpensWithTheTriggersBusyAppsAndPlaysFromThere() async throws {
        let first = trigger(30)
        let worker = SpikeProcess(name: "Busy worker", pid: 42, startTime: date(0), value: 360)
        let moments = (1...90).map { second in
            var sample = SpikeSample(time: date(Double(second)), interval: 1)
            sample.cpu = second == 30 ? 0.9 : 0.01
            return SpikeMoment(sample: sample, topCPU: second == 30 ? [worker] : [])
        }
        let capture = SpikeCapture(triggers: [first, trigger(50, kind: .memory)], moments: moments,
                                   cleared: date(40), logicalCores: 4)
        let machine = RecordingMachine(modelIdentifier: "test", modelName: "Test Mac", chip: "Test chip",
                                       memory: 8 << 30, macOSVersion: "14", macOSBuild: "test")
        let file = try RecordingFile.decode(capture.recording(machine: machine, generator: "test", exported: date(100)).encoded())
        let recorder = try FlightRecorder(replaying: file, from: URL(fileURLWithPath: "/never/written.otmrecording"))
        let points = try await recorder.points(from: file.session.start, to: file.session.end, bucket: file.recordSeconds)
        let opening = try #require(SpikeReplay.openingMoment(incident: file.incident))
        let point = try #require(HistoryPoint.nearest(to: opening, in: points))
        #expect(point.time == first.time)
        #expect(point.values.cpu == 0.9)
        let records = try await recorder.records(from: point.time.addingTimeInterval(-file.recordSeconds), to: point.time)
        #expect(HistoryRecord.topApps(in: records, count: 5).cpu == [HistoryApp(name: "Busy worker", value: 360)])
        let finalRecords = try await recorder.records(from: file.session.end.addingTimeInterval(-1), to: file.session.end)
        #expect(HistoryRecord.topApps(in: finalRecords, count: 5).cpu.isEmpty)
        for speed in HistoryPlayback.speeds {
            let start = HistoryPlayback.start(playhead: opening, pinned: nil, in: points)
            #expect(start == first.time)
            let step = try #require(HistoryPlayback.step(after: start, in: points, speed: speed))
            #expect(step.time > first.time)
        }
    }
}
