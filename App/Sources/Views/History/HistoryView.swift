import OTMKit
import SwiftUI

/// How far back the History page looks.
enum HistoryRange: Int, CaseIterable, Identifiable {
    case hour = 3_600
    case sixHours = 21_600
    case day = 86_400
    case week = 604_800

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }

    /// Seconds per graph point: about 360 across the page, never finer than a record.
    var bucket: TimeInterval { max(FlightRecorder.span, seconds / 360) }

    var timeLabels: Date.FormatStyle {
        self == .week ? .dateTime.weekday(.abbreviated).hour() : .dateTime.hour().minute()
    }
}

/// The moment the pointer last rested on. Only the scrubber lines and the
/// side panel read it, so moving the pointer never redraws the charts.
@Observable
@MainActor
final class HistoryScrubber {
    var time: Date?
}

/// The flight recorder's history: what the Mac was doing over the last hour
/// to week, with the busiest apps at any moment the pointer rests on.
///
/// The page reads the recording when it opens, when the range changes and
/// once per graph point after that. It never follows the sampling tick.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("historyRange") private var range: HistoryRange = .hour
    @State private var scrubber = HistoryScrubber()
    @State private var points: [HistoryPoint]?
    @State private var domain = Date.now.addingTimeInterval(-HistoryRange.hour.seconds)...Date.now
    @State private var earliest: Date?
    @State private var fileSize: Int64 = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding(20)
            }
            // In a scroll view of its own, so it sits under the toolbar like the charts.
            ScrollView {
                HistoryMomentPanel(scrubber: scrubber, points: points ?? [], bucket: range.bucket)
                    .padding([.top, .bottom, .trailing], 20)
            }
            .frame(width: 310)
        }
        .task(id: range) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(range.bucket))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.largeTitle.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if model.recorder == nil {
            ContentUnavailableView("History isn't available", systemImage: "exclamationmark.triangle",
                                   description: Text("The recording at \(FlightRecorder.defaultURL.path) couldn't be opened."))
        } else if let points, points.isEmpty {
            ContentUnavailableView("Collecting history", systemImage: "clock.arrow.circlepath",
                                   description: Text("A record is written every \(Int(FlightRecorder.span)) seconds while OpenTaskManager runs."))
                .padding(.top, 60)
        } else if let points {
            ForEach(HistoryChartSpec.all(for: points)) { spec in
                HistoryChartCard(spec: spec, points: points, domain: domain, earliest: earliest,
                                 timeLabels: range.timeLabels, scrubber: scrubber)
            }
        }
    }

    private var status: String {
        var parts = ["Recorded every \(Int(FlightRecorder.span)) s while OpenTaskManager runs, kept for 7 days"]
        if let earliest {
            parts.append("since \(earliest.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        }
        if fileSize > 0 { parts.append(Format.bytes(UInt64(fileSize)) + " on disk") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let recorder = model.recorder else { return }
        let end = Date.now
        let start = end.addingTimeInterval(-range.seconds)
        let loaded = (try? await recorder.points(from: start, to: end, bucket: range.bucket)) ?? []
        earliest = try? await recorder.earliest()
        fileSize = recorder.fileSize
        domain = start...end
        points = loaded
    }
}
