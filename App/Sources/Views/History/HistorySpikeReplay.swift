import OTMKit
import SwiftUI

private struct HistorySpikeIncidentKey: EnvironmentKey {
    static let defaultValue: SpikeIncident? = nil
}

extension EnvironmentValues {
    var historySpikeIncident: SpikeIncident? {
        get { self[HistorySpikeIncidentKey.self] }
        set { self[HistorySpikeIncidentKey.self] = newValue }
    }
}

/// Stays in the replay banner while the timeline folds or the charts
/// scroll, so the trigger is always one click away. Pauses there to let
/// the user read that second's busiest apps before resuming.
struct HistoryJumpToSpike: View {
    let incident: SpikeIncident
    let scrubber: HistoryScrubber
    let player: HistoryPlayer

    var body: some View {
        Button {
            guard let time = SpikeReplay.openingMoment(incident: incident) else { return }
            player.pause()
            scrubber.hover(nil)
            scrubber.pin(nil)
            scrubber.selectedEvent = nil
            scrubber.playhead = time
        } label: {
            Label("Jump to Spike", systemImage: HistoryEventStyle.symbol(.spike))
        }
        .fixedSize()
        .help((["Return to the first trigger and pause playback."] + incident.triggers.map(Self.label)).joined(separator: "\n"))
    }

    static func label(_ trigger: SpikeTrigger) -> String {
        "\(trigger.kind.shortLabel) spike at \(trigger.time.formatted(.dateTime.year().month().day().hour().minute().second()))"
    }
}

/// Static rules and the rail's bolt capsules, placed only when the chart
/// lays out. This view reads no scrubber state and schedules no frames.
struct HistorySpikeChartMarks: View {
    let incident: SpikeIncident
    let plot: CGRect
    let domain: ClosedRange<Date>

    var body: some View {
        let markers = SpikeReplay.markers(incident: incident, within: domain)
        ZStack(alignment: .topLeading) {
            ForEach(markers.indices, id: \.self) { index in
                let marker = markers[index]
                let x = plot.minX + plot.width * marker.fraction
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color(nsColor: .labelColor).opacity(0.62))
                        .frame(width: 1, height: plot.height)
                    HistoryEventMarker(symbol: HistoryEventStyle.symbol(.spike), count: 1, picked: false)
                        .accessibilityHidden(true)
                }
                .frame(width: HistoryEventMarker.size, height: plot.height)
                .offset(x: x - HistoryEventMarker.size / 2, y: plot.minY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(HistoryJumpToSpike.label(marker.trigger))
            }
        }
        .allowsHitTesting(false)
    }
}
