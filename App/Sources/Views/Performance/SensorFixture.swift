#if DEBUG
import Foundation
import OTMKit

/// A recording from `otm sensors --extremes N --json`, passed as
/// `-sensorFixture <file>`, that stands in for this Mac's sensors so the
/// Thermals page can be checked on a Mac or VM that has none. Debug builds only.
struct SensorFixture {
    let report: SensorExtremesReport

    var sensors: SensorSample? { report.sensors }

    static func load() -> SensorFixture? {
        guard let path = LaunchArgument.string("sensorFixture"),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SensorExtremesReport.self, from: data)).map(SensorFixture.init)
    }

    /// The rows as they read at the end of the recording. While the table's
    /// ranges are empty, the recording's lowest and highest go in first.
    func readings(seeding extremes: inout SensorExtremes) -> [SensorReading] {
        if extremes.samples == 0 {
            extremes.record(report.rows.map { Self.reading($0.reading, value: $0.lowest) }, thermalState: nil)
            extremes.record(report.rows.map { Self.reading($0.reading, value: $0.highest) }, thermalState: nil)
        }
        return report.rows.map(\.reading)
    }

    private static func reading(_ reading: SensorReading, value: Double?) -> SensorReading {
        SensorReading(id: reading.id, group: reading.group, rank: reading.rank, label: reading.label, unit: reading.unit,
                      source: reading.source, origin: reading.origin, value: value, note: reading.note, scale: reading.scale)
    }
}
#endif
