import Foundation
@testable import OTMKit
import Testing

struct MediaEngineTests {
    private let topology = CPUTopology(
        brand: "Test", architecture: "arm64", physicalCores: 0, logicalCores: 0, tiers: [], tierForCPU: [],
        l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil, l3CacheBytes: nil, isAppleSilicon: true
    )
    private func channel(_ name: String, _ values: [(String, Int64)], subgroup: String = "SOC Floor") -> IOReportChannel {
        IOReportChannel(group: "PMP0", subgroup: subgroup, name: name, unit: "events", driverID: 1,
                        value: .states(values.map { .init(name: $0.0, residency: $0.1) }))
    }

    @Test func expensiveMediaReadsHaveTheirOwnCadence() {
        var cadence = MediaEngineCadence()
        let decisions = [
            cadence.shouldRead(at: 0, live: false), cadence.shouldRead(at: 1, live: false),
            cadence.shouldRead(at: 2, live: false), cadence.shouldRead(at: 2, live: true),
            cadence.shouldRead(at: 3, live: true), cadence.shouldRead(at: 4, live: true),
            cadence.shouldRead(at: 8, live: false), cadence.shouldRead(at: 9, live: false),
            cadence.shouldRead(at: 0, live: false), cadence.shouldRead(at: .nan, live: true),
        ]
        #expect(decisions == [true, false, false, true, false, true, false, true, true, false])
    }

    @Test func readsKnownMediaDomainsAndExcludesOtherFloors() {
        for name in ["AVE0", "AVE1", "AVD", "MSR0", "MSR1", "JPEG", "SCODEC", "PRORES"] {
            #expect(SoCPowerAnalyzer.wants(group: "PMP0", channel: name))
        }
        for name in ["SOC", "ANE", "DISP", "AFI-BW", "AVERY", "AVE-1", "AVE16", "PRORES_OTHER"] {
            #expect(!SoCPowerAnalyzer.wants(group: "PMP0", channel: name))
        }
        #expect(!SoCPowerAnalyzer.wants(group: "PMP1", channel: "AVE0"))
    }

    @Test func measuresTimeAboveMinimumAndSortsIndependentBlocks() {
        var analyzer = SoCPowerTests.analyzer()
        let result = analyzer.analyze([
            channel("PRORES", [("VMIN", 50), ("VNOM", 50)]),
            channel("AVE0", [("VMIN", 700), ("VNOM", 200), ("VMAX", 50), ("VOVD", 50)]),
            channel("AVD", [("VMIN", 100), ("VNOM", 0)]),
        ], interval: 1, systemWatts: nil, smcCPUWatts: { nil })
        #expect(result.mediaEngines.map(\.channel) == ["AVE0", "AVD", "PRORES"])
        #expect(result.mediaEngines.map(\.activeFraction) == [0.3, 0, 0.5])
        #expect(result.mediaEngines.map(\.label) == ["Video encode 0", "Video decode", "ProRes"])
    }

    @Test func doesNotInventActivityForStalledUnknownOrInvalidCounters() {
        var analyzer = SoCPowerTests.analyzer()
        let result = analyzer.analyze([
            channel("PRORES", [("VMIN", 0), ("VNOM", 0)]),
            channel("AVE0", [("VMIN", -10), ("VNOM", 50)]),
            channel("AVD", [("VMIN", 10), ("FUTURE", 50)]),
            channel("MSR0", [("VNOM", 50)]),
            channel("MSR1", [("VMIN", 10)], subgroup: "Other"),
            channel("SOC", [("VMIN", 10)]),
        ], interval: 1, systemWatts: nil, smcCPUWatts: { nil })
        #expect(result.mediaEngines.isEmpty)
        let invalid = analyzer.analyze([channel("AVE0", [("VMIN", 10)])], interval: 0, systemWatts: nil, smcCPUWatts: { nil })
        #expect(invalid.mediaEngines.isEmpty)
    }

    @Test func mediaReadingsReachRecordedHardwareEvenWhenSlowSensorsAreSkipped() {
        let power = PowerSample(systemWatts: nil, battery: nil, isLowPowerMode: false, thermalState: .nominal,
                                adapter: nil, systemWattsSource: nil, components: nil,
                                mediaEngines: [.init(channel: "AVE0", activeFraction: 0.25), .init(channel: "AVD", activeFraction: 0)])
        var held = power
        held.mediaEnginesFresh = false
        #expect(SensorTable.readings(sensors: nil, power: held, gpus: [], freshMediaOnly: true).allSatisfy { !$0.id.hasPrefix("media/") })
        #expect(SensorTable.readings(sensors: nil, power: held, gpus: []).contains { $0.id.hasPrefix("media/") })
        let rows = SensorTable.readings(sensors: nil, power: power, gpus: [])
        let hardware = HistoryHardwareSample(readings: rows, cpu: .zero, topology: topology, sensorsRead: false)
        #expect(hardware.values["media.active.AVE0"] == 0.25)
        #expect(hardware.values["media.active.AVD"] == 0)
        #expect(hardware.series.allSatisfy { $0.kind == .media && $0.unit == .fraction })
        #expect(hardware.series.first?.source == "IOReport PMP0 SOC Floor AVE0")
        let missing = HistoryHardwareSample(readings: [], cpu: .zero, topology: topology)
        #expect(missing.values["media.active.AVE0"] == nil)
    }

    @Test func persistsMediaHistoryAndPreservesMissingIntervals() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try FlightRecorder(url: folder.appendingPathComponent("history.sqlite"))
        let series = HistoryHardwareSeries(id: "media.active.AVE0", kind: .media, unit: .fraction, label: "Video encode 0",
                                          source: "IOReport PMP0 SOC Floor AVE0", rank: 0)
        var values = HistoryValues()
        values.hardware[series.id] = 0.25
        let first = HistoryRecord(time: Date(timeIntervalSince1970: 1010), values: values, hardwareSeries: [series])
        try await recorder.append(first)
        try await recorder.append(HistoryRecord(time: Date(timeIntervalSince1970: 1020), values: HistoryValues()))
        let read = try await recorder.records(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 1030))
        #expect(read.first?.values.hardware[series.id] == 0.25)
        #expect(read.last?.values.hardware[series.id] == nil)
        let track = try await recorder.hardware(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 1030), bucket: 10)
        #expect(track.series == [series])
    }

    @Test func oldPowerSnapshotsDecodeWithoutMediaAndNewOnesRoundTrip() throws {
        let power = PowerSample(systemWatts: nil, battery: nil, isLowPowerMode: false, thermalState: .nominal,
                                adapter: nil, systemWattsSource: nil, components: nil)
        let data = try JSONEncoder().encode(power)
        #expect(try JSONDecoder().decode(PowerSample.self, from: data).mediaEngines == nil)
        var measured = power
        measured.mediaEngines = [.init(channel: "PRORES", activeFraction: 0.5)]
        let encoded = try JSONEncoder().encode(measured)
        #expect(try JSONDecoder().decode(PowerSample.self, from: encoded).mediaEngines == measured.mediaEngines)
    }
}
