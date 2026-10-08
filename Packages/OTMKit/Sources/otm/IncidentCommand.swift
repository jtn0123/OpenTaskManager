import Foundation
import OTMKit

/// Reads the app's database without migration, sampling or writing evidence back to it.
func incidentCommand(_ options: Options) async {
    guard let text = options.at, let time = IncidentLaunchTime.parse(text) else {
        fail("usage: otm incident --at ISO8601_TIME [--minutes N (1–15)] [--json]")
    }
    do {
        let recorder = try FlightRecorder(reading: FlightRecorder.defaultURL)
        let timeline = try await recorder.incident(IncidentWindow(at: time, minutes: options.incidentMinutes))
        let report = IncidentExport(timeline)
        if options.json {
            print(String(decoding: try report.json(), as: UTF8.self))
        } else {
            print(report.markdown())
        }
    } catch { fail("couldn't read incident evidence: \(error.localizedDescription)") }
}
