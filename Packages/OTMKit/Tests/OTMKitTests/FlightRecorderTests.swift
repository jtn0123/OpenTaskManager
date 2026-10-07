import Foundation
@testable import OTMKit
import Testing

struct HistoryAccumulatorTests {
    private func values(cpu: Double, watts: Double? = nil) -> HistoryValues {
        var values = HistoryValues()
        values.cpu = cpu
        values.cpuPeak = cpu
        values.systemWatts = watts
        return values
    }

    @Test func emitsOneRecordPerSpanWithTimeWeightedAverages() {
        var accumulator = HistoryAccumulator(span: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        var records: [HistoryRecord] = []
        for second in 1...20 {
            let cpu = second <= 5 ? 0.2 : 0.6
            if let record = accumulator.add(values(cpu: cpu), apps: [], interval: 1, at: start.addingTimeInterval(Double(second))) {
                records.append(record)
            }
        }
        #expect(records.count == 2)
        #expect(records[0].time == start.addingTimeInterval(10))
        #expect(abs(records[0].values.cpu - 0.4) < 1e-9)
        #expect(records[0].values.cpuPeak == 0.6)
        #expect(abs(records[1].values.cpu - 0.6) < 1e-9)
    }

    @Test func averagesOptionalFiguresOnlyOverTicksThatHaveThem() {
        var accumulator = HistoryAccumulator(span: 4)
        let start = Date(timeIntervalSince1970: 0)
        _ = accumulator.add(values(cpu: 0.1, watts: 10), apps: [], interval: 2, at: start.addingTimeInterval(2))
        let record = accumulator.add(values(cpu: 0.1), apps: [], interval: 2, at: start.addingTimeInterval(4))
        #expect(record?.values.systemWatts == 10)
        #expect(record?.values.gpu == nil)
    }

    @Test func ranksAppsByAverageCPUAndPeakMemory() {
        var accumulator = HistoryAccumulator(span: 2)
        let start = Date(timeIntervalSince1970: 0)
        _ = accumulator.add(values(cpu: 0.5), apps: [
            AppUsage(name: "Safari", cpuPercent: 40, memory: 100),
            AppUsage(name: "Mail", cpuPercent: 10, memory: 300),
        ], interval: 1, at: start.addingTimeInterval(1))
        let record = accumulator.add(values(cpu: 0.5), apps: [
            AppUsage(name: "Mail", cpuPercent: 50, memory: 200),
            AppUsage(name: "Idle", cpuPercent: 0, memory: 0),
        ], interval: 1, at: start.addingTimeInterval(2))
        #expect(record?.topCPU == [HistoryApp(name: "Mail", value: 30), HistoryApp(name: "Safari", value: 20)])
        #expect(record?.topMemory == [HistoryApp(name: "Mail", value: 300), HistoryApp(name: "Safari", value: 100)])
    }

    @Test func dropsLongTicksAndStartsAfreshAfterAGap() {
        var accumulator = HistoryAccumulator(span: 10)
        let start = Date(timeIntervalSince1970: 0)
        for second in 1...6 {
            _ = accumulator.add(values(cpu: 0.9), apps: [], interval: 1, at: start.addingTimeInterval(Double(second)))
        }
        // The Mac slept: the first tick after it covers far more than a stretch.
        #expect(accumulator.add(values(cpu: 0.9), apps: [], interval: 600, at: start.addingTimeInterval(606)) == nil)
        var record: HistoryRecord?
        for second in 1...10 {
            record = accumulator.add(values(cpu: 0.1), apps: [], interval: 1, at: start.addingTimeInterval(606 + Double(second)))
        }
        #expect(record?.time == start.addingTimeInterval(616))
        #expect(abs((record?.values.cpu ?? 0) - 0.1) < 1e-9)
    }

    @Test func mergesTopAppsAcrossStretches() {
        let records = [
            HistoryRecord(time: .now, values: HistoryValues(), topCPU: [HistoryApp(name: "A", value: 60)],
                          topMemory: [HistoryApp(name: "A", value: 5)]),
            HistoryRecord(time: .now, values: HistoryValues(), topCPU: [HistoryApp(name: "B", value: 40), HistoryApp(name: "A", value: 20)],
                          topMemory: [HistoryApp(name: "A", value: 9), HistoryApp(name: "B", value: 7)]),
        ]
        let top = HistoryRecord.topApps(in: records, count: 5)
        #expect(top.cpu == [HistoryApp(name: "A", value: 40), HistoryApp(name: "B", value: 20)])
        #expect(top.memory == [HistoryApp(name: "A", value: 9), HistoryApp(name: "B", value: 7)])
    }

    @Test func numbersSegmentsBetweenGaps() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [0.0, 10, 20, 100, 110, 400].map { HistoryPoint(time: base.addingTimeInterval($0), values: HistoryValues()) }
        #expect(HistoryPoint.segmented(points, gap: 25).map(\.segment) == [0, 0, 0, 1, 1, 2])
    }
}

struct FlightRecorderTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("otm-recorder-\(UUID().uuidString)")
            .appendingPathComponent("history.sqlite")
    }

    private func record(at seconds: Double, cpu: Double, gpu: Double? = nil, app: String = "Safari") -> HistoryRecord {
        var values = HistoryValues()
        values.cpu = cpu
        values.cpuPeak = cpu + 0.1
        values.gpu = gpu
        values.diskRead = 1_000
        return HistoryRecord(time: Date(timeIntervalSince1970: seconds), values: values,
                             topCPU: [HistoryApp(name: app, value: cpu * 100)],
                             topMemory: [HistoryApp(name: app, value: 2_000_000_000)])
    }

    @Test func storesRecordsAndReadsThemBack() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.append(record(at: 1_000_010, cpu: 0.25, gpu: 0.5))
        try await recorder.append(record(at: 1_000_020, cpu: 0.75, app: "Xcode"))

        let records = try await recorder.records(from: Date(timeIntervalSince1970: 1_000_000), to: Date(timeIntervalSince1970: 1_000_020))
        #expect(records.count == 2)
        #expect(records[0].values.gpu == 0.5)
        #expect(records[1].values.gpu == nil)
        #expect(records[1].topCPU == [HistoryApp(name: "Xcode", value: 75)])
        #expect(records[1].topMemory.first?.value == 2_000_000_000)
        #expect(try await recorder.earliest() == Date(timeIntervalSince1970: 1_000_010))
        #expect(recorder.fileSize > 0)
    }

    @Test func averagesRecordsIntoBucketsAndMarksGaps() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        // Two buckets of 60 s, then a gap of ten minutes.
        for (seconds, cpu) in [(10.0, 0.2), (20, 0.4), (70, 0.6), (80, 0.8), (700, 0.1)] {
            try await recorder.append(record(at: 1_200_000 + seconds, cpu: cpu))
        }
        let points = try await recorder.points(from: Date(timeIntervalSince1970: 1_200_000),
                                               to: Date(timeIntervalSince1970: 1_201_000), bucket: 60)
        #expect(points.count == 3)
        #expect(abs(points[0].values.cpu - 0.3) < 1e-9)
        #expect(abs(points[0].values.cpuPeak - 0.5) < 1e-9)
        #expect(points[0].time == Date(timeIntervalSince1970: 1_200_020))
        #expect(points[0].values.gpu == nil)
        #expect(points.map(\.segment) == [0, 0, 1])
    }

    @Test func prunesOldRecordsAndKeepsTheRestAcrossReopening() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(record(at: 100, cpu: 0.1))
            try await recorder.append(record(at: 200, cpu: 0.2))
            try await recorder.prune(before: Date(timeIntervalSince1970: 150))
        }
        let reopened = try FlightRecorder(url: url)
        let records = try await reopened.records(from: .distantPast, to: .distantFuture)
        #expect(records.map(\.values.cpu) == [0.2])
    }
}
