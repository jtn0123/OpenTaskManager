import AppKit
import OTMKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// The range in a sentence: "recorded in the last hour".
    var phrase: String {
        switch self {
        case .hour: "the last hour"
        case .sixHours: "the last 6 hours"
        case .day: "the last 24 hours"
        case .week: "the last 7 days"
        }
    }

    /// Seconds between labelled times on the axis.
    var tickStep: TimeInterval {
        switch self {
        case .hour: 15 * 60
        case .sixHours: 60 * 60
        case .day: 4 * 60 * 60
        case .week: 24 * 60 * 60
        }
    }

    var timeLabels: Date.FormatStyle {
        self == .week ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute()
    }
}

/// The moment the History page shows. A click or drag on a graph or the rail
/// pins it, and it stays when the pointer leaves; hovering previews another
/// moment without moving the pin. Only the markers, the rail's handle and
/// the side panel read it, so moving the pointer never redraws the charts.
@Observable
@MainActor
final class HistoryScrubber {
    /// The moment a click or drag picked; nil follows the latest.
    var pinned: Date?
    /// The moment under the pointer while it's over a graph or the rail.
    var hovered: Date?

    /// What the side panel shows: the previewed moment, else the pinned one,
    /// else (nil) the latest.
    var time: Date? { hovered ?? pinned }
}

/// The flight recorder's history: what the Mac was doing over the last hour
/// to week, with the busiest apps at any moment picked on the graphs.
///
/// The page reads the recording when it opens, when the range changes and
/// once per graph point after that. It never follows the sampling tick.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("historyRange") private var range: HistoryRange = .hour
    /// Spread the graphs over just the recorded part of a range the recording doesn't fill.
    @AppStorage("historyFitsRecording") private var fitsRecording = false
    @State private var scrubber = HistoryScrubber()
    @State private var points: [HistoryPoint]?
    @State private var domain = Date.now.addingTimeInterval(-HistoryRange.hour.seconds)...Date.now
    /// Seconds each graph point averages.
    @State private var bucket = FlightRecorder.span
    @State private var earliest: Date?
    /// Seconds recorded within the range, gaps left out.
    @State private var recorded: TimeInterval = 0
    /// Whether the recording began inside the range, so fitting would change the graphs.
    @State private var canFit = false
    @State private var fileSize: Int64 = 0

    private struct LoadKey: Equatable {
        let range: HistoryRange
        let fits: Bool
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                // The rail is a pinned header, so it stays over the charts as they scroll.
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                    header
                    Section {
                        content
                    } header: {
                        rail
                    }
                }
                .padding(20)
            }
            // In a scroll view of its own, so it sits under the toolbar like the charts.
            ScrollView {
                HistoryMomentPanel(scrubber: scrubber, points: points ?? [], bucket: bucket)
                    .padding([.top, .bottom, .trailing], 20)
            }
            .frame(width: 310)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await export() }
                } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .help("Save every record in this range as a CSV file")
                .disabled(model.recorder == nil)
            }
        }
        .task(id: LoadKey(range: range, fits: fitsRecording)) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(bucket))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("History").font(.largeTitle.weight(.semibold))
                Spacer()
                fitToggle
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            (Text(recordedLabel).foregroundStyle(.primary).fontWeight(.medium) + Text(status).foregroundStyle(.secondary))
                .font(.callout)
        }
    }

    /// Spreads the graphs over the recorded stretch only. Offered only while
    /// the recording began inside the range; it never stretches the data.
    private var fitToggle: some View {
        Toggle(isOn: Binding(get: { fitsRecording && canFit }, set: { fitsRecording = $0 })) {
            Label("Fit recorded data", systemImage: "arrow.left.and.right")
        }
        .toggleStyle(.button)
        .disabled(!canFit)
        .help(canFit ? "Spread the graphs over the recorded time only, instead of all of \(range.phrase)"
            : "The recording already covers \(range.phrase)")
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
            let axis = timeAxis
            ForEach(HistoryChartSpec.all(for: points)) { spec in
                HistoryChartCard(spec: spec, points: points, domain: domain, earliest: earliest,
                                 ticks: GraphMath.timeTicks(in: domain, step: axis.step, margin: 0.08),
                                 timeLabels: axis.labels, scrubber: scrubber)
            }
        }
    }

    /// The timeline over the charts, once there's something to pick from.
    @ViewBuilder private var rail: some View {
        if let points, !points.isEmpty, model.recorder != nil {
            HistoryRail(scrubber: scrubber, points: points, domain: domain, bucket: bucket)
                .padding(.top, 4)
                .padding(.bottom, 8)
                // Covers the charts as they scroll under the pinned rail.
                .background(.background)
        }
    }

    /// Where the time axis is labelled: the range's own steps, or round
    /// steps for a fitted span.
    private var timeAxis: (step: TimeInterval, labels: Date.FormatStyle) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span < range.seconds - 1 else { return (range.tickStep, range.timeLabels) }
        let step = GraphMath.timeTickStep(for: span)
        let labels: Date.FormatStyle = step < 60 ? .dateTime.hour().minute().second()
            : step >= 86_400 ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute()
        return (step, labels)
    }

    /// How much of the range is recorded: "17 min recorded since 6:51 AM".
    private var recordedLabel: String {
        guard let earliest, recorded > 0 else { return "" }
        guard canFit else { return "\(Format.roughDuration(recorded)) recorded in \(range.phrase)" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(earliest)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return "\(Format.roughDuration(recorded)) recorded since \(earliest.formatted(style))"
    }

    /// The rest of the line under the title, after `recordedLabel`.
    private var status: String {
        var parts = ["every \(Int(FlightRecorder.span)) s while OpenTaskManager runs, kept for 7 days"]
        if fileSize > 0 { parts.append(Format.bytes(UInt64(fileSize)) + " on disk") }
        let text = parts.joined(separator: " · ")
        return recordedLabel.isEmpty ? "Recorded " + text : " · " + text
    }

    /// Saves the records in the range shown, at full resolution, as CSV.
    private func export() async {
        guard let recorder = model.recorder else { return }
        let records = (try? await recorder.records(from: domain.lowerBound, to: .now)) ?? []
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "OpenTaskManager history \(Date.now.formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryRecord.csv(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func load() async {
        guard let recorder = model.recorder else { return }
        let end = Date.now
        let first = try? await recorder.earliest()
        let age = first.map { end.timeIntervalSince($0) }
        let span = GraphMath.historySpan(range: range.seconds, recorded: age, fit: fitsRecording)
        let step = FlightRecorder.bucket(for: span)
        let start = end.addingTimeInterval(-span)
        let loaded = (try? await recorder.points(from: start, to: end, bucket: step)) ?? []
        recorded = (try? await recorder.recordedSeconds(from: end.addingTimeInterval(-range.seconds), to: end)) ?? 0
        earliest = first
        canFit = GraphMath.canFit(range: range.seconds, recorded: age)
        fileSize = recorder.fileSize
        bucket = step
        domain = start...end
        points = loaded
        // A pinned moment that has slid out of the range goes back to the latest.
        if let pinned = scrubber.pinned, !domain.contains(pinned) { scrubber.pinned = nil }
    }
}
