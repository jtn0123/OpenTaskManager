import Foundation
import OTMKit

private struct ListenerChangesReport: Encodable {
    let baseline: ListenerBaseline?
    let changes: [ListenerChange]
    let unreadableProcesses: Int
}

/// The CLI reads the app's saved review, and settles live differences without ever initializing or accepting a baseline.
func listenerChangesCommand(_ options: Options) async {
    var reader = ListenerIdentityReader()
    var debounce = ListenerDebounce()
    let first = ConnectionSampler.sample()
    let before = reader.read(first)
    _ = debounce.observe(before.listeners, at: first.time, maximumSpacing: 7)
    do { try await Task.sleep(for: .seconds(3)) } catch { fail("listener walk cancelled") }
    let second = ConnectionSampler.sample()
    let after = reader.read(second)
    let confirmed = debounce.observe(after.listeners, at: second.time, maximumSpacing: 7)
    let saved: ListenerReview?
    do {
        if FileManager.default.fileExists(atPath: FlightRecorder.defaultURL.path) {
            saved = try await FlightRecorder(reading: FlightRecorder.defaultURL).listenerReview()
        } else {
            saved = nil
        }
    } catch { fail("could not read listener baseline: \(error.localizedDescription)") }
    var review = saved
    review?.record(confirmed, at: second.time)
    let report = ListenerChangesReport(baseline: review?.baseline, changes: review?.changes ?? [],
                                       unreadableProcesses: max(before.unreadableProcesses, after.unreadableProcesses))
    if options.json {
        printJSON(report)
    } else {
        if let baseline = report.baseline {
            print("Baseline reviewed \(baseline.reviewedAt.formatted()) with \(baseline.listeners.count) listeners")
            for change in report.changes {
                print("\(change.id.transport.rawValue) \(change.id.portLabel(seen: change.listener.connection.local.port)) · \(change.id.scope.label) · \(change.id.executable.path)")
                print("  " + change.reasons.map(\.label).joined(separator: "; "))
                for holder in change.previousHolders { print("  Previously reviewed: " + holder) }
            }
            if report.changes.isEmpty { print("No listener changes observed against the saved baseline.") }
        } else {
            print("No saved listener baseline. Open Connections to set one; this command leaves it unset.")
        }
        if report.unreadableProcesses > 0 { print("\(report.unreadableProcesses) processes unreadable; their listeners are unknown.") }
    }
}
