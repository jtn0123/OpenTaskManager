import Foundation

/// A stretch of the flight recorder the user marked, with an optional note:
/// what a recording file holds.
public struct RecordingSession: Sendable, Hashable, Identifiable {
    /// The session's row in the recorder; 0 for one read from a file.
    public let id: Int64
    /// Where the session begins: the start of its first record's stretch.
    public let start: Date
    /// Where it ends: the end of its last record's stretch.
    public let end: Date
    public let note: String

    /// The ends are put in order and the note trimmed.
    public init(id: Int64 = 0, start: Date, end: Date, note: String = "") {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Whether the record ending at `time` falls in the session. A record
    /// covers the stretch up to its time, so one ending at `start` doesn't.
    public func contains(_ time: Date) -> Bool {
        time > start && time <= end
    }
}

/// The Mac a recording was made on, so a file opened elsewhere says whose
/// figures they are. Nothing that singles out the machine itself (serial
/// number, hardware UUID, computer name) goes in.
public struct RecordingMachine: Sendable, Equatable {
    /// `hw.model`, such as "Mac17,8".
    public let modelIdentifier: String
    /// "MacBook Pro (16-inch, M5 Pro)"; nil on Macs without one (Intel).
    public let modelName: String?
    /// "Apple M5 Pro".
    public let chip: String
    /// Physical memory in bytes.
    public let memory: UInt64
    /// "27.2".
    public let macOSVersion: String
    /// "26B5101f".
    public let macOSBuild: String?

    public init(modelIdentifier: String, modelName: String?, chip: String, memory: UInt64, macOSVersion: String, macOSBuild: String?) {
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.chip = chip
        self.memory = memory
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
    }

    public var displayName: String { modelName ?? modelIdentifier }

    /// "MacBook Pro (16-inch, M5 Pro) · Apple M5 Pro · 32 GB · macOS 27.2".
    public var summary: String {
        [displayName, chip, SystemFacts.memorySize(memory), "macOS \(macOSVersion)"].joined(separator: " · ")
    }
}

/// The figures a Mac may not report: no GPU statistics in a VM, no power
/// or temperature sensors on some models.
public enum RecordingFigure: String, Sendable, CaseIterable, Codable {
    case gpu
    case systemWatts
    case cpuWatts
    case gpuWatts
    case chipCelsius

    var keyPath: KeyPath<HistoryValues, Double?> {
        switch self {
        case .gpu: \.gpu
        case .systemWatts: \.systemWatts
        case .cpuWatts: \.cpuWatts
        case .gpuWatts: \.gpuWatts
        case .chipCelsius: \.chipCelsius
        }
    }
}

public enum RecordingFileError: Error, Equatable, LocalizedError {
    /// The file isn't JSON, or its contents are damaged or missing.
    case corrupt(String)
    /// The file is JSON but not an OpenTaskManager recording.
    case notARecording
    /// A format version this build can't read: made by a newer app.
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let detail): "The recording is damaged and can't be read (\(detail))."
        case .notARecording: "This file isn't an OpenTaskManager recording."
        case .unsupportedVersion(let version):
            "This recording is in format version \(version), and this copy of OpenTaskManager reads up to version "
                + "\(RecordingFile.version). Open it with a newer OpenTaskManager."
        }
    }
}

/// A self-contained recording: the flight recorder's records for one
/// session, with what another Mac needs to read them (which Mac made them,
/// how long each record covers, the units, which figures it reported).
///
/// Saved as versioned JSON with the `otmrecording` extension. Every time is
/// in seconds since 1970 UTC; a figure the Mac didn't report is `null` in a
/// record, never zero, and `reported` says which ones it reported at all.
///
/// `events` came later, within version 1: an optional key that a file
/// written before it simply lacks (it has no events), and that a build from
/// before it ignores, as JSON readers ignore keys they don't know. An event
/// of a kind this build doesn't know is left out.
///
/// The hardware series came the same way: an optional top-level `hardware`
/// block, versioned on its own (`hardwareVersion`), that names each series
/// once (ID, kind, unit, label, source), and in each record a `hardware`
/// object of figures by series ID, `null` where the Mac didn't read one, and
/// `coreLoad`, each logical CPU's load. A build from before them reads the
/// rest of the file as it always did; this one skips a block of a newer
/// version, and a series of a kind or unit it doesn't know, rather than
/// misread them.
public struct RecordingFile: Sendable, Equatable {
    /// Marks the JSON as a recording, whatever the file's name.
    public static let format = "io.github.jtn0123.OpenTaskManager.recording"
    public static let fileExtension = "otmrecording"
    /// The version this build writes, and the newest it reads.
    public static let version = 1
    /// The version of the `hardware` block this build writes, and the newest it reads.
    public static let hardwareVersion = 1

    public var session: RecordingSession
    public var machine: RecordingMachine
    /// The app that wrote the file: "OpenTaskManager 0.1.0".
    public var generator: String
    public var exported: Date
    /// Seconds each record covers.
    public var recordSeconds: TimeInterval
    /// Whether the Mac reported each figure it may not, at least once in the session.
    public var reported: [RecordingFigure: Bool]
    /// Oldest first.
    public var records: [HistoryRecord]
    /// What happened during the session, oldest first; none in a file from
    /// before events were kept.
    public var events: [HistoryEvent]
    /// The hardware series any record holds, in chart order; none in a file
    /// from before they were kept.
    public var hardwareSeries: [HistoryHardwareSeries] {
        Set(records.flatMap(\.hardwareSeries)).sorted()
    }

    public init(session: RecordingSession, machine: RecordingMachine, generator: String, exported: Date,
                recordSeconds: TimeInterval = FlightRecorder.span, records: [HistoryRecord], events: [HistoryEvent] = []) {
        self.session = session
        self.machine = machine
        self.generator = generator
        self.exported = exported
        self.recordSeconds = recordSeconds
        self.records = records.sorted { $0.time < $1.time }
        self.events = events.sorted { $0.time < $1.time }
        reported = Dictionary(uniqueKeysWithValues: RecordingFigure.allCases.map { figure in
            (figure, records.contains { $0.values[keyPath: figure.keyPath] != nil })
        })
    }

    /// What each field of a record measures, written into the file for anyone reading it without this app.
    static let units: [String: String] = [
        "time": "seconds since 1970-01-01 00:00 UTC, at the end of the stretch the record covers",
        "cpu": "share of the whole CPU, 0 to 1, averaged over the stretch",
        "cpuPeak": "share of the whole CPU, 0 to 1, at the busiest update in the stretch",
        "memory": "share of physical memory in use, 0 to 1",
        "memoryPressure": "memory pressure, 0 to 1",
        "swapUsed": "bytes",
        "gpu": "busiest GPU's utilization, 0 to 1",
        "systemWatts": "watts", "cpuWatts": "watts", "gpuWatts": "watts",
        "diskRead": "bytes per second", "diskWrite": "bytes per second",
        "networkIn": "bytes per second", "networkOut": "bytes per second",
        "chipCelsius": "degrees Celsius, the hottest die sensor",
        "topCPU": "the busiest apps by CPU, in percent of one core (100 = one core)",
        "topMemory": "the apps using the most memory, in bytes",
        "hardware": "hardware figures by the ID of a series in the top-level hardware block, in that series' unit "
            + "(fraction 0 to 1, megahertz, rpm, celsius or watts), averaged over the updates in the stretch that read "
            + "it; null when none did",
        "coreLoad": "each logical CPU's load, 0 to 1, by CPU number, averaged over the stretch; null for a CPU with no reading",
        "events": "what happened during the session (kind appLaunched, appQuit, processStarted, processExited, "
            + "networkChanged, sleep or wake), each at a time in seconds since 1970-01-01 00:00 UTC; approximate "
            + "when found by comparing one update's process list with the next",
    ]

    // MARK: - Encoding

    /// The file's bytes: compact JSON with sorted keys.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(self))
    }

    /// Reads a recording, checking that it is one and that this build
    /// understands its version before reading the rest.
    public static func decode(_ data: Data) throws(RecordingFileError) -> RecordingFile {
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch DecodingError.dataCorrupted {
            throw .corrupt("it isn't valid JSON")
        } catch {
            throw .notARecording
        }
        guard header.format == format else { throw .notARecording }
        guard let version = header.version, (1...Self.version).contains(version) else {
            throw .unsupportedVersion(header.version ?? 0)
        }
        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: data)
        } catch {
            throw .corrupt(describe(error))
        }
        guard wire.sampling.recordSeconds > 0, wire.session.start <= wire.session.end else {
            throw .corrupt("its session or sampling interval doesn't make sense")
        }
        var file = RecordingFile(
            session: RecordingSession(start: Date(timeIntervalSince1970: wire.session.start),
                                      end: Date(timeIntervalSince1970: wire.session.end), note: wire.session.note),
            machine: wire.machine.machine,
            generator: wire.generator,
            exported: Date(timeIntervalSince1970: wire.exported),
            recordSeconds: wire.sampling.recordSeconds,
            records: wire.records.map { $0.record(series: wire.hardware?.readable ?? [:]) },
            events: (wire.events ?? []).compactMap(\.event)
        )
        // The file's own flags win: they say what the Mac reported, which a
        // reader shouldn't second-guess from the records.
        for figure in RecordingFigure.allCases {
            if let flag = wire.reported[figure.rawValue] { file.reported[figure] = flag }
        }
        return file
    }

    /// Where a decoding error happened, in a few words.
    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "#\($0)" } ?? $0.stringValue }
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, let context): return "\(key.stringValue) is missing from \(path(context))"
        case .valueNotFound(_, let context): return "\(path(context)) is empty"
        case .typeMismatch(_, let context): return "\(path(context)) has the wrong kind of value"
        case .dataCorrupted(let context): return "\(path(context)) is unreadable"
        default: return error.localizedDescription
        }
    }
}

// MARK: - Wire format

/// Version 1 of the file, kept apart from the app's types so changing those
/// never changes the format by accident.
private struct Header: Decodable {
    let format: String?
    let version: Int?
}

private struct Wire: Codable {
    struct Session: Codable {
        let start: Double
        let end: Double
        let note: String
    }

    struct Machine: Codable {
        let modelIdentifier: String
        let modelName: String?
        let chip: String
        let memoryBytes: UInt64
        let macOSVersion: String
        let macOSBuild: String?

        var machine: RecordingMachine {
            RecordingMachine(modelIdentifier: modelIdentifier, modelName: modelName, chip: chip, memory: memoryBytes,
                             macOSVersion: macOSVersion, macOSBuild: macOSBuild)
        }
    }

    struct Sampling: Codable {
        let recordSeconds: Double
    }

    let format: String
    let version: Int
    let generator: String
    let exported: Double
    let session: Session
    let machine: Machine
    let sampling: Sampling
    let units: [String: String]?
    let reported: [String: Bool]
    let records: [WireRecord]
    /// Missing from files written before events were kept.
    let events: [WireEvent]?
    /// Missing from files without hardware series.
    let hardware: WireHardware?

    init(_ file: RecordingFile) {
        format = RecordingFile.format
        version = RecordingFile.version
        generator = file.generator
        exported = file.exported.timeIntervalSince1970
        session = Session(start: file.session.start.timeIntervalSince1970, end: file.session.end.timeIntervalSince1970,
                          note: file.session.note)
        let machine = file.machine
        self.machine = Machine(modelIdentifier: machine.modelIdentifier, modelName: machine.modelName, chip: machine.chip,
                               memoryBytes: machine.memory, macOSVersion: machine.macOSVersion, macOSBuild: machine.macOSBuild)
        sampling = Sampling(recordSeconds: file.recordSeconds)
        units = RecordingFile.units
        reported = Dictionary(uniqueKeysWithValues: file.reported.map { ($0.key.rawValue, $0.value) })
        let series = file.hardwareSeries
        let ids = series.map(\.id)
        records = file.records.map { WireRecord($0, hardware: series.isEmpty ? nil : ids) }
        events = file.events.map(WireEvent.init)
        hardware = series.isEmpty ? nil : WireHardware(version: RecordingFile.hardwareVersion, series: series.map(WireSeries.init))
    }
}

/// The `hardware` block: the series the records' figures belong to.
private struct WireHardware: Codable {
    let version: Int
    let series: [WireSeries]

    /// The series by ID that this build can read: none from a newer
    /// version of the block, and none of a kind or unit it doesn't know.
    var readable: [String: HistoryHardwareSeries] {
        guard version >= 1, version <= RecordingFile.hardwareVersion else { return [:] }
        return Dictionary(series.compactMap(\.series).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct WireSeries: Codable {
    let id: String
    /// A `HistoryHardwareSeries.Kind`: load, clock, temperature, fan or power.
    let kind: String
    /// A `SensorUnit`: fraction, megahertz, rpm, celsius or watts.
    let unit: String
    let label: String
    let source: String
    let rank: Int

    init(_ series: HistoryHardwareSeries) {
        id = series.id
        kind = series.kind.rawValue
        unit = series.unit.rawValue
        label = series.label
        source = series.source
        rank = series.rank
    }

    var series: HistoryHardwareSeries? {
        guard let kind = HistoryHardwareSeries.Kind(rawValue: kind), let unit = SensorUnit(rawValue: unit) else { return nil }
        return HistoryHardwareSeries(id: id, kind: kind, unit: unit, label: label, source: source, rank: rank)
    }
}

private struct WireEvent: Codable {
    let time: Double
    /// A `HistoryEvent.Kind`; one this build doesn't know is skipped.
    let kind: String
    let name: String
    let detail: String
    let count: Int
    let approximate: Bool

    init(_ event: HistoryEvent) {
        time = event.time.timeIntervalSince1970
        kind = event.kind.rawValue
        name = event.name
        detail = event.detail
        count = event.count
        approximate = event.isApproximate
    }

    var event: HistoryEvent? {
        guard time.isFinite, let kind = HistoryEvent.Kind(rawValue: kind) else { return nil }
        return HistoryEvent(time: Date(timeIntervalSince1970: time), kind: kind, name: name, detail: detail, count: count,
                            isApproximate: approximate)
    }
}

private struct WireApp: Codable {
    let name: String
    let value: Double
}

private struct WireRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case time, cpu, cpuPeak, memory, memoryPressure, swapUsed, gpu, systemWatts, cpuWatts, gpuWatts
        case diskRead, diskWrite, networkIn, networkOut, chipCelsius, topCPU, topMemory, hardware, coreLoad
    }

    let time: Double
    let cpu: Double
    let cpuPeak: Double
    let memory: Double
    let memoryPressure: Double
    let swapUsed: Double
    let gpu: Double?
    let systemWatts: Double?
    let cpuWatts: Double?
    let gpuWatts: Double?
    let diskRead: Double
    let diskWrite: Double
    let networkIn: Double
    let networkOut: Double
    let chipCelsius: Double?
    let topCPU: [WireApp]
    let topMemory: [WireApp]
    /// Figures by series ID, null where the Mac didn't read one; missing
    /// from a file without hardware series.
    let hardware: [String: Double?]?
    let coreLoad: [Double?]?

    /// `hardware` lists the file's series IDs, each written (null where it
    /// wasn't read) for every record with a hardware figure, or is nil for a
    /// file without hardware series. A record without any, from before they
    /// were recorded, leaves both keys out, as in the database.
    init(_ record: HistoryRecord, hardware ids: [String]?) {
        // JSON has no NaN or infinity: a figure that isn't a number reads as not reported.
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let values = record.values
        time = record.time.timeIntervalSince1970
        cpu = finite(values.cpu) ?? 0
        cpuPeak = finite(values.cpuPeak) ?? 0
        memory = finite(values.memory) ?? 0
        memoryPressure = finite(values.memoryPressure) ?? 0
        swapUsed = finite(values.swapUsed) ?? 0
        gpu = finite(values.gpu)
        systemWatts = finite(values.systemWatts)
        cpuWatts = finite(values.cpuWatts)
        gpuWatts = finite(values.gpuWatts)
        diskRead = finite(values.diskRead) ?? 0
        diskWrite = finite(values.diskWrite) ?? 0
        networkIn = finite(values.networkIn) ?? 0
        networkOut = finite(values.networkOut) ?? 0
        chipCelsius = finite(values.chipCelsius)
        topCPU = record.topCPU.map { WireApp(name: $0.name, value: finite($0.value) ?? 0) }
        topMemory = record.topMemory.map { WireApp(name: $0.name, value: finite($0.value) ?? 0) }
        let figures = ids.map { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, finite(values.hardware[$0])) }) }
        let loads = ids == nil || values.coreLoads.isEmpty ? nil : values.coreLoads.map(finite)
        let read = figures?.values.contains { $0 != nil } == true || loads?.contains { $0 != nil } == true
        hardware = read ? figures : nil
        coreLoad = read ? loads : nil
    }

    /// Written by hand so a figure the Mac didn't report is an explicit
    /// `null`, not a missing key a reader might take for zero.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(cpuPeak, forKey: .cpuPeak)
        try container.encode(memory, forKey: .memory)
        try container.encode(memoryPressure, forKey: .memoryPressure)
        try container.encode(swapUsed, forKey: .swapUsed)
        try container.encode(gpu, forKey: .gpu)
        try container.encode(systemWatts, forKey: .systemWatts)
        try container.encode(cpuWatts, forKey: .cpuWatts)
        try container.encode(gpuWatts, forKey: .gpuWatts)
        try container.encode(diskRead, forKey: .diskRead)
        try container.encode(diskWrite, forKey: .diskWrite)
        try container.encode(networkIn, forKey: .networkIn)
        try container.encode(networkOut, forKey: .networkOut)
        try container.encode(chipCelsius, forKey: .chipCelsius)
        try container.encode(topCPU, forKey: .topCPU)
        try container.encode(topMemory, forKey: .topMemory)
        try container.encodeIfPresent(hardware, forKey: .hardware)
        try container.encodeIfPresent(coreLoad, forKey: .coreLoad)
    }

    /// The record, its hardware figures named from `series` (the file's
    /// readable series by ID); a figure of any other series is left out.
    func record(series: [String: HistoryHardwareSeries]) -> HistoryRecord {
        var values = HistoryValues()
        values.cpu = cpu
        values.cpuPeak = cpuPeak
        values.memory = memory
        values.memoryPressure = memoryPressure
        values.swapUsed = swapUsed
        values.gpu = gpu
        values.systemWatts = systemWatts
        values.cpuWatts = cpuWatts
        values.gpuWatts = gpuWatts
        values.diskRead = diskRead
        values.diskWrite = diskWrite
        values.networkIn = networkIn
        values.networkOut = networkOut
        values.chipCelsius = chipCelsius
        var held: [HistoryHardwareSeries] = []
        for (id, value) in hardware ?? [:] {
            guard let value, value.isFinite, let named = series[id] else { continue }
            values.hardware[id] = value
            held.append(named)
        }
        if !series.isEmpty { values.coreLoads = coreLoad ?? [] }
        return HistoryRecord(time: Date(timeIntervalSince1970: time), values: values,
                             topCPU: topCPU.map { HistoryApp(name: $0.name, value: $0.value) },
                             topMemory: topMemory.map { HistoryApp(name: $0.name, value: $0.value) },
                             hardwareSeries: held.sorted())
    }
}
