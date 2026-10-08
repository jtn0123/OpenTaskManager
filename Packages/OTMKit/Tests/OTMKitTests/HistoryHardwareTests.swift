import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("otm-hardware-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

/// Two Super and two Performance logical CPUs.
private let topology = CPUTopology(
    brand: "Apple M5 Pro", architecture: "arm64", physicalCores: 4, logicalCores: 4,
    tiers: [CPUTopology.Tier(level: 0, name: "Super", logicalCPUs: 2, physicalCPUs: 2, l2CacheBytes: nil),
            CPUTopology.Tier(level: 1, name: "Performance", logicalCPUs: 2, physicalCPUs: 2, l2CacheBytes: nil)],
    tierForCPU: [0, 0, 1, 1], l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil, l3CacheBytes: nil,
    isAppleSilicon: true
)

private func cpu(_ cores: [Double]) -> CPUSample {
    CPUSample(usage: cores.reduce(0, +) / Double(max(cores.count, 1)), user: 0, system: 0, coreUsage: cores, loadAverage: [0, 0, 0])
}

private func row(_ id: String, _ group: SensorGroup, _ unit: SensorUnit, _ value: Double?, label: String = "",
                 source: SensorSource = .smc, origin: String? = nil, rank: Int = 0) -> SensorReading {
    SensorReading(id: id, group: group, rank: rank, label: label, unit: unit, source: source, origin: origin, value: value)
}

/// The Thermals table's rows as an M5 Pro on its battery gives them, with
/// one cluster idle, the DRAM counters stalled and an M1-style CPU sensor.
private func readings() -> [SensorReading] {
    [
        row("chip/hottest", .chip, .celsius, 61, label: "Hottest", source: .derived),
        row("chip/average", .chip, .celsius, 52.5, label: "Average", source: .derived, rank: 1),
        row("temperature/PMU tdie1", .chip, .celsius, 56, label: "Die 1", source: .hidSensor, origin: "PMU tdie1", rank: 100),
        row("temperature/PMU tdie12", .chip, .celsius, 49, label: "Die 12", source: .hidSensor, origin: "PMU tdie12", rank: 100),
        row("temperature/pACC MTR Temp Sensor3", .cpu, .celsius, 61, label: "Performance cores 3", source: .hidSensor,
            origin: "pACC MTR Temp Sensor3", rank: 100),
        row("cpu/power", .cpu, .watts, 17.5, label: "Power", source: .ioReportEnergy),
        row("cpu/PCPU/clock", .cpu, .megahertz, 4_096, label: "Super 0 clock", source: .ioReport, origin: "PCPU", rank: 10),
        row("cpu/PCPU/active", .cpu, .fraction, 0.9, label: "Super 0 active", source: .ioReport, origin: "PCPU", rank: 11),
        row("cpu/MCPU0/clock", .cpu, .megahertz, nil, label: "Performance 0 clock", source: .ioReport, origin: "MCPU0", rank: 13),
        row("gpu/Apple M5 Pro42/clock", .gpu, .megahertz, 338, label: "Clock", source: .ioReport, origin: "Apple M5 Pro", rank: 10),
        row("ane/power", .neuralEngine, .watts, 0.25, label: "Power", source: .ioReportEnergy, origin: "ANE"),
        row("temperature/NAND CH0 temp", .storage, .celsius, 37, label: "SSD channel 0", source: .hidSensor, origin: "NAND CH0 temp"),
        row("temperature/gas gauge battery", .battery, .celsius, 30.5, label: "Temperature", source: .hidSensor,
            origin: "gas gauge battery"),
        row("battery/power", .battery, .watts, -4, label: "Power", source: .batteryGauge, rank: 3),
        row("power/system", .power, .watts, 25, label: "System total", origin: "PSTR"),
        row("power/input", .power, .watts, nil, label: "DC input", origin: "PDTR", rank: 1),
        row("rail/VD0R", .power, .volts, 27.7, label: "DC input voltage", origin: "VD0R", rank: 2),
        row("fan/0", .fans, .rpm, 1_356, label: "Fan 1", origin: "F0Ac"),
        row("fan/1", .fans, .rpm, 1_461, label: "Fan 2", origin: "F1Ac", rank: 1),
    ]
}

private func series(_ id: String, _ kind: HistoryHardwareSeries.Kind, _ unit: SensorUnit, rank: Int = 0) -> HistoryHardwareSeries {
    HistoryHardwareSeries(id: id, kind: kind, unit: unit, label: id, source: "test \(id)", rank: rank)
}

/// A record with hardware figures, each exact as a 32-bit float and each
/// core load a whole half percent, so it reads back from the recorder unchanged.
private func hardwareRecord(at seconds: Double, fan: Double? = 1_356, clock: Double? = 4_096, cores: [Double?] = [0.5, 0.25]) -> HistoryRecord {
    var values = HistoryValues()
    values.cpu = 0.375
    values.cpuPeak = 0.5
    values.chipCelsius = 48.5
    var held: [HistoryHardwareSeries] = []
    if let fan {
        values.hardware["fan.0"] = fan
        held.append(series("fan.0", .fan, .rpm))
    }
    if let clock {
        values.hardware["cpu.clock.PCPU"] = clock
        held.append(series("cpu.clock.PCPU", .clock, .megahertz, rank: 10))
    }
    values.hardware["temperature.ssd"] = 37.25
    held.append(series("temperature.ssd", .temperature, .celsius, rank: 3))
    values.coreLoads = cores
    return HistoryRecord(time: date(seconds), values: values, hardwareSeries: held.sorted())
}

// MARK: - Picking the series

struct HistoryHardwareSampleTests {
    @Test func picksAFewSeriesWithStableIDsUnitsAndSources() throws {
        let sample = HistoryHardwareSample(readings: readings(), cpu: cpu([1, 0.5, 0.25, 0.25]), topology: topology)
        #expect(sample.values == [
            "cpu.load.busiest": 1, "cpu.load.super": 0.75, "cpu.load.performance": 0.25,
            "cpu.clock.PCPU": 4_096, "gpu.clock": 338,
            "temperature.cpu": 61, "temperature.average": 52.5, "temperature.ssd": 37, "temperature.battery": 30.5,
            "fan.0": 1_356, "fan.1": 1_461, "power.ane": 0.25,
        ])
        #expect(sample.coreLoads == [1, 0.5, 0.25, 0.25])
        let byID = Dictionary(uniqueKeysWithValues: sample.series.map { ($0.id, $0) })
        #expect(Set(byID.keys) == Set(sample.values.keys))
        let superCores = try #require(byID["cpu.load.super"])
        #expect(superCores.kind == .load)
        #expect(superCores.unit == .fraction)
        #expect(superCores.label == "Super cores")
        #expect(superCores.source == "host_processor_info, mean of the 2 logical CPUs at hw.perflevel0")
        #expect(byID["cpu.clock.PCPU"]?.label == "Super 0")
        #expect(byID["cpu.clock.PCPU"]?.unit == .megahertz)
        #expect(byID["fan.0"]?.source == "SMC F0Ac")
        #expect(byID["fan.1"]?.unit == .rpm)
        #expect(byID["power.ane"]?.source == "IOReport ANE")
        #expect(byID["temperature.ssd"]?.source == "HID sensors NAND CH0 temp")
        #expect(byID["temperature.average"]?.source == "HID sensors PMU tdie*, pACC MTR Temp Sensor*, mean")
        // In chart order: loads by tier then the busiest, clocks, temperatures, fans, power.
        #expect(sample.series.sorted().map(\.id) == [
            "cpu.load.super", "cpu.load.performance", "cpu.load.busiest", "cpu.clock.PCPU", "gpu.clock",
            "temperature.cpu", "temperature.average", "temperature.ssd", "temperature.battery", "fan.0", "fan.1", "power.ane",
        ])
    }

    @Test func leavesOutWhatWasntReadRatherThanCountItAsZero() {
        let sample = HistoryHardwareSample(readings: readings(), cpu: cpu([1, 0.5, 0.25, 0.25]), topology: topology)
        // An idle cluster has no clock, stalled DRAM counters no power, an unplugged Mac no DC input,
        // and a CPU die sensor on one Mac means none for the GPU.
        for missing in ["cpu.clock.MCPU0", "power.dram", "power.input", "temperature.gpu"] {
            #expect(sample.values[missing] == nil)
        }
        // A battery's signed power and the SMC's volts aren't kept.
        #expect(!sample.values.keys.contains { $0.contains("battery.power") || $0.contains("VD0R") })
    }

    @Test func skipsSensorRowsAnUpdateDidntReadAgain() {
        let sample = HistoryHardwareSample(readings: readings(), cpu: cpu([1, 0.5, 0.25, 0.25]), topology: topology, sensorsRead: false)
        #expect(!sample.values.keys.contains { $0.hasPrefix("temperature.") || $0.hasPrefix("fan.") })
        #expect(sample.values["cpu.clock.PCPU"] == 4_096)
        #expect(sample.values["power.ane"] == 0.25)
        #expect(sample.values["cpu.load.busiest"] == 1)
    }

    @Test func keepsCoreTypesOnlyWhenTheMapMatchesTheCPUs() {
        let short = HistoryHardwareSample(readings: [], cpu: cpu([1, 0.5, 0.25]), topology: topology)
        #expect(short.values == ["cpu.load.busiest": 1])
        let plain = CPUTopology(brand: "Intel", architecture: "x86_64", physicalCores: 2, logicalCores: 2,
                                tiers: [CPUTopology.Tier(level: 0, name: "Core", logicalCPUs: 2, physicalCPUs: 2, l2CacheBytes: nil)],
                                tierForCPU: [0, 0], l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil,
                                l3CacheBytes: nil, isAppleSilicon: false)
        #expect(HistoryHardwareSample(readings: [], cpu: cpu([0.5, 0.25]), topology: plain).values == ["cpu.load.busiest": 0.5])
        #expect(HistoryHardwareSample(readings: [], cpu: .zero, topology: topology).values.isEmpty)
    }
}

// MARK: - Folding updates into records

struct HistoryHardwareAccumulatorTests {
    private func sample(fan: Double?, clock: Double?, cores: [Double?]) -> HistoryHardwareSample {
        var sample = HistoryHardwareSample()
        if let fan { sample.add(series("fan.0", .fan, .rpm), fan) }
        if let clock { sample.add(series("cpu.clock.PCPU", .clock, .megahertz, rank: 10), clock) }
        sample.setCoreLoads(cores)
        return sample
    }

    @Test func averagesEachFigureOverTheUpdatesThatReadIt() throws {
        var accumulator = HistoryAccumulator(span: 4)
        let first = accumulator.add(HistoryValues(), hardware: sample(fan: 1_000, clock: 4_000, cores: [1, nil]), apps: [],
                                    interval: 1, at: date(1))
        #expect(first == nil)
        let second = accumulator.add(HistoryValues(), hardware: sample(fan: 2_000, clock: nil, cores: [0, 0.5]), apps: [],
                                     interval: 3, at: date(4))
        let record = try #require(second)
        // Time-weighted: one second at 1,000 rpm, three at 2,000.
        #expect(record.values.hardware["fan.0"] == 1_750)
        // The clock was read for one second only: its average is that, not diluted by the idle three.
        #expect(record.values.hardware["cpu.clock.PCPU"] == 4_000)
        #expect(record.values.coreLoads == [0.25, 0.5])
        #expect(record.hardwareSeries.map(\.id) == ["cpu.clock.PCPU", "fan.0"])
    }

    @Test func keepsAFigureNoUpdateReadMissing() throws {
        var accumulator = HistoryAccumulator(span: 2)
        _ = accumulator.add(HistoryValues(), hardware: sample(fan: nil, clock: nil, cores: []), apps: [], interval: 1, at: date(1))
        let closed = accumulator.add(HistoryValues(), apps: [], interval: 1, at: date(2))
        let record = try #require(closed)
        #expect(record.values.hardware.isEmpty)
        #expect(record.values.coreLoads.isEmpty)
        #expect(record.hardwareSeries.isEmpty)
    }

    @Test func startsAfreshAfterAGap() throws {
        var accumulator = HistoryAccumulator(span: 4)
        _ = accumulator.add(HistoryValues(), hardware: sample(fan: 5_000, clock: 3_000, cores: [1]), apps: [], interval: 1, at: date(1))
        // Asleep for a minute: the next stretch has none of the figures before it.
        _ = accumulator.add(HistoryValues(), hardware: sample(fan: 1_000, clock: nil, cores: [0.5]), apps: [], interval: 2, at: date(62))
        let closed = accumulator.add(HistoryValues(), hardware: sample(fan: 1_000, clock: nil, cores: [0.5]), apps: [],
                                     interval: 2, at: date(64))
        let record = try #require(closed)
        #expect(record.values.hardware == ["fan.0": 1_000])
        #expect(record.values.coreLoads == [0.5])
        #expect(record.hardwareSeries.map(\.id) == ["fan.0"])
    }
}

// MARK: - Lines across missing readings

struct HistoryRunTests {
    private func points(_ values: [Double?], segments: [Int]) -> [HistoryPoint] {
        zip(values, segments).enumerated().map { index, pair in
            var figures = HistoryValues()
            figures.gpu = pair.0
            return HistoryPoint(time: date(Double(index) * 10), values: figures, segment: pair.1)
        }
    }

    @Test func breaksALineAtAMissingReadingAndAtAGap() {
        let points = points([1, nil, 2, 3, 4, nil], segments: [0, 0, 0, 0, 1, 1])
        let runs = HistoryPoint.runs(points, value: \.gpu)
        #expect(runs == [0, nil, 1, 1, 2, nil])
        // Dots where the line breaks off for the missing reading and picks up
        // again; a gap's borders are the gap marks' to dot.
        #expect(HistoryPoint.breaks(points, runs: runs) == [0, 2, 4])
    }

    @Test func drawsAnUnbrokenLineAsOneRun() {
        let points = points([1, 2, 3], segments: [0, 0, 0])
        let runs = HistoryPoint.runs(points, value: \.gpu)
        #expect(runs == [0, 0, 0])
        #expect(HistoryPoint.breaks(points, runs: runs).isEmpty)
        #expect(HistoryPoint.runs(points, value: \.systemWatts) == [nil, nil, nil])
        #expect(HistoryPoint.lone(runs).isEmpty)
    }

    @Test func findsTheRunsOfOnePoint() {
        // A point alone between missing readings, one between a missing reading and a gap, then a run of two.
        let points = points([nil, 1, nil, 2, 3, 4], segments: [0, 0, 0, 0, 1, 1])
        let runs = HistoryPoint.runs(points, value: \.gpu)
        #expect(runs == [nil, 0, nil, 1, 2, 2])
        #expect(HistoryPoint.lone(runs) == [0, 1])
    }
}

// MARK: - The recorder's storage

struct FlightRecorderHardwareTests {
    @Test func roundTripsHardwareFiguresThroughTheDatabase() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let records = [hardwareRecord(at: 1_010), hardwareRecord(at: 1_020, fan: nil, cores: [nil, 1]), hardwareRecord(at: 1_030)]
        for record in records { try await recorder.append(record) }
        let read = try await recorder.records(from: date(1_000), to: date(1_100))
        #expect(read == records)
        // The missing fan stays missing, never zero.
        #expect(read[1].values.hardware["fan.0"] == nil)
        #expect(read[1].values.coreLoads == [nil, 1])
    }

    @Test func keepsATypicalRecordsHardwareSmall() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            // An M5 Pro's: 3 loads, 3 clocks, 3 temperatures, 2 fans, 3 rails, and 18 cores.
            var values = HistoryValues()
            var held: [HistoryHardwareSeries] = []
            for index in 0..<14 {
                values.hardware["series.\(index)"] = Double(index)
                held.append(series("series.\(index)", .power, .watts, rank: index))
            }
            values.coreLoads = Array(repeating: 0.5, count: 18)
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(HistoryRecord(time: date(10), values: values, hardwareSeries: held))
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT length(hardware) FROM records", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        // About 6 bytes a series and one a core.
        #expect(sqlite3_column_int(statement, 0) == 1 + 2 + 14 * 6 + 2 + 18)
    }

    @Test func readsBytesOfAnotherLayoutAsNoFigures() {
        let good = Data([1, 1, 0, 3, 0, 0x00, 0x00, 0x80, 0x3F, 2, 0, 100, 255])
        let decoded = good.withUnsafeBytes { HardwareBlob.decode($0) }
        #expect(decoded?.figures.map { $0.row } == [3])
        #expect(decoded?.figures.map { $0.value } == [1])
        #expect(decoded?.coreLoads == [0.5, nil])
        var newer = good
        newer[0] = 2
        #expect(newer.withUnsafeBytes { HardwareBlob.decode($0) } == nil)
        #expect(good.dropLast().withUnsafeBytes { HardwareBlob.decode($0) } == nil)
        #expect(Data().withUnsafeBytes { HardwareBlob.decode($0) } == nil)
    }

    @Test func bucketsTheFiguresAsTheGraphPointsAreGrouped() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.append(hardwareRecord(at: 1_005, fan: 1_000))
        try await recorder.append(hardwareRecord(at: 1_010, fan: 2_000, clock: nil))
        try await recorder.append(hardwareRecord(at: 1_025, fan: 3_000))
        // A record an older build wrote: no hardware figures.
        var plain = HistoryValues()
        plain.cpu = 0.5
        try await recorder.append(HistoryRecord(time: date(1_045), values: plain))

        let points = try await recorder.points(from: date(1_000), to: date(1_060), bucket: 20)
        let track = try await recorder.hardware(from: date(1_000), to: date(1_060), bucket: 20)
        #expect(track.earliest == date(1_005))
        #expect(track.series.map(\.id) == ["cpu.clock.PCPU", "temperature.ssd", "fan.0"])
        #expect(track.coreCount == 2)
        let shown = track.overlay(points)
        #expect(shown.map(\.time) == points.map(\.time))
        #expect(shown.map(\.segment) == points.map(\.segment))
        #expect(shown.map { $0.values.hardware["fan.0"] } == [1_500, 3_000, nil])
        // Averaged over the records that read it.
        #expect(shown.map { $0.values.hardware["cpu.clock.PCPU"] } == [4_096, 4_096, nil])
        #expect(shown[2].values.coreLoads.isEmpty)
        #expect(shown.map(\.values.cpu) == points.map(\.values.cpu))
    }

    @Test func leavesOutSeriesOfAKindThisBuildDoesntKnow() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(hardwareRecord(at: 1_010))
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "UPDATE hardware_series SET kind = 'humidity' WHERE key = 'fan.0'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try FlightRecorder(url: url)
        let record = try #require(try await reopened.records(from: date(1_000), to: date(1_100)).first)
        #expect(record.values.hardware == ["cpu.clock.PCPU": 4_096, "temperature.ssd": 37.25])
        #expect(record.hardwareSeries.map(\.id) == ["cpu.clock.PCPU", "temperature.ssd"])
    }

    @Test func sumsUpHardwareFiguresForACompare() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.append(hardwareRecord(at: 1_010, fan: 1_000))
        try await recorder.append(hardwareRecord(at: 1_020, fan: 2_000))
        let stats = try await recorder.stats(from: date(1_000), to: date(1_020))
        let fan = HistoryMetric.hardware(series("fan.0", .fan, .rpm))
        #expect(stats.figures[fan]?.average == 1_500)
        #expect(stats.figures[.chipTemperature]?.average == 48.5)
        #expect(stats.metrics.suffix(3).map(\.rawValue) == ["hardware.cpu.clock.PCPU", "hardware.temperature.ssd", "hardware.fan.0"])
    }
}

// MARK: - Schema 2

struct FlightRecorderSchemaTwoTests {
    /// A database as the events build (schema 1) left it.
    private func makeVersionOne(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE records (time REAL PRIMARY KEY, cpu REAL, cpu_peak REAL, memory REAL, pressure REAL, swap REAL,
                gpu REAL, system_watts REAL, cpu_watts REAL, gpu_watts REAL, disk_read REAL, disk_write REAL, net_in REAL,
                net_out REAL, chip_celsius REAL, top_cpu TEXT, top_memory TEXT) WITHOUT ROWID;
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            CREATE TABLE events (time REAL NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '', count INTEGER NOT NULL DEFAULT 1, approximate INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX events_once ON events (kind, name, CAST(time AS INTEGER));
            CREATE INDEX events_time ON events (time);
            INSERT INTO records VALUES (1000, 0.25, 0.5, 0.6, 0.2, 0, 0.1, 12, 4, 1, 100, 200, 300, 400, 51.5,
                '[{"n":"Safari","v":25}]', '[{"n":"Safari","v":1000}]');
            INSERT INTO sessions (start_time, end_time, note) VALUES (990, 1000, 'Before hardware');
            INSERT INTO events (time, kind, name) VALUES (995, 'appLaunched', 'Safari');
            PRAGMA user_version = 1;
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func bringsAVersionOneDatabaseUpToDateKeepingEverything() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeVersionOne(at: url)

        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        let old = try #require(try await recorder.records(from: date(0), to: date(2_000)).first)
        #expect(old.values.chipCelsius == 51.5)
        #expect(old.values.systemWatts == 12)
        #expect(old.values.hardware.isEmpty)
        #expect(old.values.coreLoads.isEmpty)
        #expect(old.topCPU == [HistoryApp(name: "Safari", value: 25)])
        #expect(try await recorder.sessions().map(\.note) == ["Before hardware"])
        #expect(try await recorder.events(from: date(0), to: date(2_000)).map(\.name) == ["Safari"])
        // It keeps hardware figures from now on.
        try await recorder.append(hardwareRecord(at: 1_010))
        #expect(try await recorder.records(from: date(1_005), to: date(2_000)) == [hardwareRecord(at: 1_010)])
        #expect(try await recorder.hardware(from: date(0), to: date(2_000), bucket: 10).earliest == date(1_010))
    }

    @Test func opensASchemaTwoDatabaseAgainWithoutMigrating() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(hardwareRecord(at: 1_010))
        }
        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        try await reopened.append(hardwareRecord(at: 1_020, fan: 2_000))
        let records = try await reopened.records(from: date(1_000), to: date(1_100))
        #expect(records.map { $0.values.hardware["fan.0"] } == [1_356, 2_000])
    }

    /// What a schema-1 build does with the database: skip the migration, as
    /// `user_version` is past its own, then read and write its own columns.
    @Test func anOlderBuildStillReadsAndWritesASchemaTwoDatabase() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(hardwareRecord(at: 1_010))
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let older = """
            CREATE TABLE IF NOT EXISTS records (time REAL PRIMARY KEY, cpu REAL, cpu_peak REAL, memory REAL, pressure REAL, swap REAL,
                gpu REAL, system_watts REAL, cpu_watts REAL, gpu_watts REAL, disk_read REAL, disk_write REAL, net_in REAL,
                net_out REAL, chip_celsius REAL, top_cpu TEXT, top_memory TEXT) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            INSERT OR REPLACE INTO records (time, cpu, cpu_peak, memory, pressure, swap, gpu, system_watts, cpu_watts, gpu_watts,
                disk_read, disk_write, net_in, net_out, chip_celsius, top_cpu, top_memory)
                VALUES (1020, 0.5, 0.5, 0.5, 0.1, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 40, '[]', '[]');
            """
        #expect(sqlite3_exec(handle, older, nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT time, cpu, chip_celsius, top_cpu FROM records ORDER BY time", -1, &statement, nil) == SQLITE_OK)
        var times: [Double] = []
        while sqlite3_step(statement) == SQLITE_ROW { times.append(sqlite3_column_double(statement, 0)) }
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        #expect(times == [1_010, 1_020])

        let recorder = try FlightRecorder(url: url)
        let records = try await recorder.records(from: date(1_000), to: date(1_100))
        #expect(records.map(\.time) == [date(1_010), date(1_020)])
        #expect(records[0].values.hardware["fan.0"] == 1_356)
        #expect(records[1].values.hardware.isEmpty)
        #expect(records[1].values.chipCelsius == 40)
    }
}

// MARK: - Recording files

struct RecordingFileHardwareTests {
    private let machine = RecordingMachine(modelIdentifier: "Mac17,8", modelName: nil, chip: "Apple M5 Pro", memory: 32 << 30,
                                           macOSVersion: "27.2", macOSBuild: nil)

    private func file(_ records: [HistoryRecord]) -> RecordingFile {
        RecordingFile(session: RecordingSession(start: date(1_000), end: date(1_100)), machine: machine,
                      generator: "OpenTaskManager 0.1.0", exported: date(1_200), records: records)
    }

    private func json(_ file: RecordingFile) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
    }

    @Test func roundTripsHardwareSeriesAndFigures() throws {
        let original = file([hardwareRecord(at: 1_010), hardwareRecord(at: 1_020, fan: nil, cores: [nil, 0.75])])
        let decoded = try RecordingFile.decode(try original.encoded())
        #expect(decoded == original)
        #expect(decoded.hardwareSeries.map(\.id) == ["cpu.clock.PCPU", "temperature.ssd", "fan.0"])
        #expect(decoded.records[1].values.hardware["fan.0"] == nil)
        #expect(decoded.records[1].values.coreLoads == [nil, 0.75])
    }

    @Test func namesEachSeriesOnceAndWritesNullsForMissingFigures() throws {
        let object = try json(file([hardwareRecord(at: 1_010), hardwareRecord(at: 1_020, fan: nil)]))
        #expect(object["version"] as? Int == 1)
        let hardware = try #require(object["hardware"] as? [String: Any])
        #expect(hardware["version"] as? Int == RecordingFile.hardwareVersion)
        let series = try #require(hardware["series"] as? [[String: Any]])
        #expect(series.map { $0["id"] as? String } == ["cpu.clock.PCPU", "temperature.ssd", "fan.0"])
        #expect(series.last?["unit"] as? String == "rpm")
        #expect(series.last?["kind"] as? String == "fan")
        let records = try #require(object["records"] as? [[String: Any]])
        let figures = try #require(records[1]["hardware"] as? [String: Any])
        #expect(figures.keys.sorted() == ["cpu.clock.PCPU", "fan.0", "temperature.ssd"])
        #expect(figures["fan.0"] is NSNull)
        #expect(records[1]["coreLoad"] as? [Double] == [0.5, 0.25])
        let units = try #require(object["units"] as? [String: String])
        #expect(units["hardware"] != nil && units["coreLoad"] != nil)
    }

    @Test func leavesHardwareOutOfARecordFromBeforeItWasRecorded() throws {
        var values = HistoryValues()
        values.cpu = 0.25
        let earlier = HistoryRecord(time: date(1_000), values: values)
        let original = file([earlier, hardwareRecord(at: 1_010)])
        let records = try #require(try json(original)["records"] as? [[String: Any]])
        #expect(records[0]["hardware"] == nil && records[0]["coreLoad"] == nil)
        #expect(records[1]["hardware"] != nil)
        let decoded = try RecordingFile.decode(try original.encoded())
        #expect(decoded == original)
        #expect(decoded.records[0].values.hardware.isEmpty && decoded.records[0].values.coreLoads.isEmpty)
    }

    @Test func writesAFileWithoutHardwareAsBefore() throws {
        var values = HistoryValues()
        values.cpu = 0.25
        let object = try json(file([HistoryRecord(time: date(1_010), values: values)]))
        #expect(object["hardware"] == nil)
        let record = try #require((object["records"] as? [[String: Any]])?.first)
        #expect(Set(record.keys) == [
            "time", "cpu", "cpuPeak", "memory", "memoryPressure", "swapUsed", "gpu", "systemWatts", "cpuWatts", "gpuWatts",
            "diskRead", "diskWrite", "networkIn", "networkOut", "chipCelsius", "topCPU", "topMemory",
        ])
        #expect(try RecordingFile.decode(try file([HistoryRecord(time: date(1_010), values: values)]).encoded()).hardwareSeries.isEmpty)
    }

    @Test func skipsANewerHardwareBlockButKeepsTheRest() throws {
        var object = try json(file([hardwareRecord(at: 1_010)]))
        var hardware = try #require(object["hardware"] as? [String: Any])
        hardware["version"] = RecordingFile.hardwareVersion + 1
        object["hardware"] = hardware
        let decoded = try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.records.count == 1)
        #expect(decoded.records[0].values.cpu == 0.375)
        #expect(decoded.records[0].values.chipCelsius == 48.5)
        #expect(decoded.records[0].values.hardware.isEmpty)
        #expect(decoded.records[0].values.coreLoads.isEmpty)
        #expect(decoded.hardwareSeries.isEmpty)
    }

    @Test func skipsASeriesOfAKindOrUnitThisBuildDoesntKnow() throws {
        var object = try json(file([hardwareRecord(at: 1_010)]))
        var hardware = try #require(object["hardware"] as? [String: Any])
        var series = try #require(hardware["series"] as? [[String: Any]])
        series[0]["kind"] = "humidity"
        series[1]["unit"] = "lux"
        hardware["series"] = series
        object["hardware"] = hardware
        let decoded = try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.hardwareSeries.map(\.id) == ["fan.0"])
        #expect(decoded.records[0].values.hardware == ["fan.0": 1_356])
    }

    @Test func stillRefusesANewerFileVersion() throws {
        var object = try json(file([hardwareRecord(at: 1_010)]))
        object["version"] = RecordingFile.version + 1
        #expect(throws: RecordingFileError.unsupportedVersion(RecordingFile.version + 1)) {
            try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func replaysAFilesHardwareSeries() async throws {
        let original = file([hardwareRecord(at: 1_010), hardwareRecord(at: 1_020, fan: 2_000)])
        let recorder = try FlightRecorder(replaying: try RecordingFile.decode(try original.encoded()), from: URL(fileURLWithPath: "/x.otmrecording"))
        let track = try await recorder.hardware(from: date(1_000), to: date(1_100), bucket: 10)
        #expect(track.series.map(\.id) == ["cpu.clock.PCPU", "temperature.ssd", "fan.0"])
        let points = try await recorder.points(from: date(1_000), to: date(1_100), bucket: 10)
        #expect(track.overlay(points).map { $0.values.hardware["fan.0"] } == [1_356, 2_000])
        // Exported again, it's the same file.
        let session = RecordingSession(start: date(1_000), end: date(1_100))
        let again = try await recorder.recording(of: session, machine: machine, generator: "OpenTaskManager 0.1.0", exported: date(1_200))
        #expect(again.records == original.records)
    }
}

// MARK: - Compare

struct HistoryHardwareComparisonTests {
    @Test func comparesHardwareSeriesAfterTheSystemFigures() throws {
        let a = HistoryIntervalStats(records: [hardwareRecord(at: 1_010, fan: 2_000)], from: date(1_000), to: date(1_010))
        let b = HistoryIntervalStats(records: [hardwareRecord(at: 2_010, fan: 1_000, clock: nil)], from: date(2_000), to: date(2_010))
        let rows = HistoryComparison(a: a, b: b).rows
        let ids = rows.map(\.id)
        let chip = try #require(ids.firstIndex(of: "chipTemperature.average"))
        #expect(ids.firstIndex(of: "cpu.average") ?? .max < chip)
        #expect(Array(ids.suffix(3)) == ["hardware.cpu.clock.PCPU.average", "hardware.temperature.ssd.average", "hardware.fan.0.average"])
        let fan = try #require(rows.first { $0.id == "hardware.fan.0.average" })
        #expect(fan.metric.title(.average) == "fan.0 speed average")
        #expect(fan.metric.format(1_356, .average) == "1,356 rpm")
        #expect(fan.change?.label(isFraction: fan.metric.isFraction) == "+100%")
        // B didn't read the clock: A has it, B shows none.
        let clock = try #require(rows.first { $0.id == "hardware.cpu.clock.PCPU.average" })
        #expect(clock.b == nil)
        #expect(clock.metric.format(4_096, .average) == "4.10 GHz")
    }

    @Test func givesATemperaturesChangeInDegrees() {
        let change = HistoryComparison.Change(a: 60.5, b: 56.4, absoluteUnit: .celsius)
        #expect(change.label(isFraction: false) == "+4.1 °C")
        #expect(HistoryComparison.Change(a: 50, b: 50.01, absoluteUnit: .celsius).label(isFraction: false) == "no change")
        #expect(HistoryMetric.chipTemperature.statistics == [.average, .peak])
        #expect(HistoryMetric.chipTemperature.format(48.5, .peak) == "48.5 °C")
    }

    @Test func keepsTheBusiestCoresPeak() {
        let busiest = HistoryHardwareSeries(id: HistoryHardwareSeries.busiestCore, kind: .load, unit: .fraction, label: "Busiest core",
                                            source: "", rank: 90)
        let metric = HistoryMetric.hardware(busiest)
        #expect(metric.statistics == [.average, .peak])
        #expect(metric.isFraction)
        #expect(metric.title(.peak) == "Busiest core peak")
        #expect(metric == HistoryMetric.hardware(busiest))
        #expect(HistoryMetric.allCases.first == .cpu)
    }
}
