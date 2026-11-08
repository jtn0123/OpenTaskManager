import OTMKit
import SwiftUI

/// A cross-page request keeps the stored identity, never whichever same-named row comes first.
@MainActor @Observable
final class IncidentNavigation {
    static let shared = IncidentNavigation()
    var job: LaunchHistoryKey?
    var socket: String?
    var search: String?
    var revealsProcess = false
}

extension AppModel {
    static let usesIncidentFixture: Bool = {
        #if DEBUG
        return LaunchArgument.string("incidentFixture") == "YES"
        #else
        return false
        #endif
    }()

    static func makeIncidentRecorder() -> FlightRecorder? {
        guard !usesIncidentFixture else { return nil }
        return try? FlightRecorder(url: FlightRecorder.defaultURL)
    }
}

/// This action reads just the pinned selection, so pointer previews never move the investigation.
struct IncidentInvestigateButton: View {
    let scrubber: HistoryScrubber
    let latest: Date?
    private let store = HistoryRecordingStore.shared

    var body: some View {
        Menu("Investigate") {
            Button("Pinned moment") {
                if let time = scrubber.pinned ?? latest { store.incidentWindow = IncidentWindow(at: time) }
            }
            .disabled(scrubber.pinned == nil && latest == nil)
            if let marked = scrubber.marked {
                Button("Marked interval") {
                    store.incidentWindow = IncidentWindow(from: marked.start, to: marked.end ?? scrubber.pinned ?? latest ?? marked.start)
                }
            }
            if let comparison = scrubber.compare {
                if let interval = comparison.a {
                    Button("Compare interval A") { store.incidentWindow = IncidentWindow(from: interval.lowerBound, to: interval.upperBound) }
                }
                if let interval = comparison.b {
                    Button("Compare interval B") { store.incidentWindow = IncidentWindow(from: interval.lowerBound, to: interval.upperBound) }
                }
            }
        }
        .controlSize(.small)
        .help("Bring resource, process, startup, socket and event evidence together for this window")
    }
}
