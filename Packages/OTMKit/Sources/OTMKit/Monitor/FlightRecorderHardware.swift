import Foundation
import SQLite3

/// The flight recorder's `hardware_series` table (schema 2): each hardware
/// series named once, with its kind, unit, label and source, so a record
/// holds only a number per series. Rows are added as series first appear
/// and brought up to date when one's description changes; none is deleted.
final class HardwareCatalogue {
    private var rows: [String: (row: Int64, series: HistoryHardwareSeries)] = [:]

    /// The series' row, added or brought up to date when this recorder
    /// hasn't written it as it is now. Another copy of the app may have
    /// added it already; the upsert returns that row.
    func row(for series: HistoryHardwareSeries, on handle: OpaquePointer) throws(FlightRecorderError) -> Int64 {
        if let cached = rows[series.id], cached.series == series { return cached.row }
        let statement = try FlightRecorder.prepare("""
            INSERT INTO hardware_series (key, kind, unit, label, source, rank) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET kind = excluded.kind, unit = excluded.unit, label = excluded.label,
                source = excluded.source, rank = excluded.rank
            RETURNING id
            """, on: handle)
        defer { sqlite3_finalize(statement) }
        FlightRecorder.bind(series.id, to: statement, at: 1)
        FlightRecorder.bind(series.kind.rawValue, to: statement, at: 2)
        FlightRecorder.bind(series.unit.rawValue, to: statement, at: 3)
        FlightRecorder.bind(series.label, to: statement, at: 4)
        FlightRecorder.bind(series.source, to: statement, at: 5)
        sqlite3_bind_int64(statement, 6, Int64(series.rank))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
        let row = sqlite3_column_int64(statement, 0)
        while sqlite3_step(statement) == SQLITE_ROW {}
        rows[series.id] = (row, series)
        return row
    }

    /// Every series in the table, by row. One of a kind or unit this build
    /// doesn't know (written by a newer one) is left out, and so are its figures.
    static func load(on handle: OpaquePointer) throws(FlightRecorderError) -> [Int64: HistoryHardwareSeries] {
        let statement = try FlightRecorder.prepare("SELECT id, key, kind, unit, label, source, rank FROM hardware_series", on: handle)
        defer { sqlite3_finalize(statement) }
        var series: [Int64: HistoryHardwareSeries] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = FlightRecorder.text(statement, 1),
                  let kind = FlightRecorder.text(statement, 2).flatMap(HistoryHardwareSeries.Kind.init(rawValue:)),
                  let unit = FlightRecorder.text(statement, 3).flatMap(SensorUnit.init(rawValue:)) else { continue }
            series[sqlite3_column_int64(statement, 0)] = HistoryHardwareSeries(
                id: key, kind: kind, unit: unit, label: FlightRecorder.text(statement, 4) ?? key,
                source: FlightRecorder.text(statement, 5) ?? "", rank: Int(sqlite3_column_int64(statement, 6))
            )
        }
        return series
    }
}

/// A record's hardware figures as the recorder's `hardware` column holds
/// them, little-endian:
///
///     u8  layout version (1)
///     u16 n, then n × (u16 series row in `hardware_series`, f32 value)
///     u16 c, then c × u8 core load in half percent (0...200; 255 = no reading)
///
/// About 6 bytes a series and 1 a core. A column of another layout reads
/// as no hardware figures, never as wrong ones.
enum HardwareBlob {
    static let version: UInt8 = 1
    /// A core with no load reading.
    static let noLoad: UInt8 = 255

    /// The bytes for `record`'s hardware figures, naming each series through
    /// `catalogue`; nil when it has none. A figure whose series isn't
    /// described in `record.hardwareSeries` is left out.
    static func encode(_ record: HistoryRecord, catalogue: HardwareCatalogue,
                       on handle: OpaquePointer) throws(FlightRecorderError) -> Data? {
        let values = record.values
        guard !values.hardware.isEmpty || values.coreLoads.contains(where: { $0 != nil }) else { return nil }
        var figures: [(row: UInt16, value: Float)] = []
        for series in record.hardwareSeries {
            guard let value = values.hardware[series.id], value.isFinite else { continue }
            let row = try catalogue.row(for: series, on: handle)
            guard let short = UInt16(exactly: row) else { continue }
            figures.append((short, Float(value)))
        }
        figures.sort { $0.row < $1.row }
        let loads = values.coreLoads.contains { $0 != nil } ? values.coreLoads : []
        guard !figures.isEmpty || !loads.isEmpty else { return nil }
        var data = Data(capacity: 5 + figures.count * 6 + loads.count)
        data.append(version)
        append(UInt16(figures.count), to: &data)
        for figure in figures {
            append(figure.row, to: &data)
            append(figure.value.bitPattern, to: &data)
        }
        append(UInt16(min(loads.count, Int(UInt16.max))), to: &data)
        for load in loads.prefix(Int(UInt16.max)) {
            data.append(load.map { UInt8((min(max($0, 0), 1) * 200).rounded()) } ?? noLoad)
        }
        return data
    }

    /// The figures in `bytes`, by series row, and each core's load; nil for
    /// bytes of another layout or cut short.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> (figures: [(row: Int64, value: Double)], coreLoads: [Double?])? {
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= bytes.count else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }
        guard read(UInt8.self) == version, let count = read(UInt16.self) else { return nil }
        var figures: [(row: Int64, value: Double)] = []
        figures.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let row = read(UInt16.self), let bits = read(UInt32.self) else { return nil }
            figures.append((Int64(row), Double(Float(bitPattern: bits))))
        }
        guard let cores = read(UInt16.self) else { return nil }
        var loads: [Double?] = []
        loads.reserveCapacity(Int(cores))
        for _ in 0..<cores {
            guard let load = read(UInt8.self) else { return nil }
            loads.append(load == noLoad ? nil : min(Double(load) / 200, 1))
        }
        return (figures, loads)
    }

    /// Reads the `hardware` column at `column` into `values`, naming each
    /// figure from `series` (`HardwareCatalogue.load`), and returns the
    /// series it holds, in chart order. A null column holds none.
    @discardableResult
    static func read(_ statement: OpaquePointer, _ column: Int32, series: [Int64: HistoryHardwareSeries],
                     into values: inout HistoryValues) -> [HistoryHardwareSeries] {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let base = sqlite3_column_blob(statement, column),
              let decoded = decode(UnsafeRawBufferPointer(start: base, count: Int(sqlite3_column_bytes(statement, column)))) else {
            return []
        }
        var held: [HistoryHardwareSeries] = []
        for figure in decoded.figures {
            guard let named = series[figure.row], figure.value.isFinite else { continue }
            values.hardware[named.id] = figure.value
            held.append(named)
        }
        values.coreLoads = decoded.coreLoads
        return held.sorted()
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
