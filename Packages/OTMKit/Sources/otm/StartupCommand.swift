import Foundation
import OTMKit

/// Reads the stored observations only; it never asks launchd for current state.
func startupCommand(_ options: Options) async {
    guard options.positional.count == 2, options.positional.first == "history" else {
        fail("usage: otm startup history LABEL [--json]")
    }
    let label = options.positional[1]
    let recorder: FlightRecorder
    do {
        recorder = try FlightRecorder(reading: FlightRecorder.defaultURL)
    } catch {
        fail("no stored history: OpenTaskManager writes it while its flight recorder is on")
    }
    do {
        guard try await recorder.keepsLaunchJobHistory() else { fail("this database has no launch job history yet") }
        let end = Date.now
        let report = try await recorder.launchJobHistory(label: label, from: end.addingTimeInterval(-FlightRecorder.retention), to: end)
        if options.json {
            printJSON(report)
        } else {
            let spans = LaunchHistoryCoverage.spansText(report.coverage)
            print("Watched: " + (spans.isEmpty ? "none in the last 7 days" : spans))
            if report.events.isEmpty { print("No stored changes for \(label) in the last 7 days."); return }
            print("\(label) · observed changes; exact times and runs between reads are unknown")
            for event in report.events.reversed() {
                print("\(event.time.formatted(date: .abbreviated, time: .standard)) · \(event.key.domain) · \(event.words)")
                if let configuration = event.configuration {
                    print("  \(configuration.path) · modified \(configuration.modified?.formatted() ?? "unknown")")
                    print("  \(configuration.program ?? "program unknown") \(configuration.arguments.joined(separator: " "))")
                }
            }
        }
    } catch { fail("couldn't read startup history: \(error.localizedDescription)") }
}
