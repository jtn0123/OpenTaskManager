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

    /// The point the moment panel shows, among `points`.
    func point(in points: [HistoryPoint]) -> HistoryPoint? {
        time.flatMap { HistoryPoint.nearest(to: $0, in: points) } ?? points.last
    }
}

/// The flight recorder's history: what the Mac was doing over the last hour
/// to week, with the busiest apps at any moment picked on the graphs.
///
/// The page reads the recording when it opens, when the range changes and
/// once per graph point after that. It never follows the sampling tick.
///
/// Below `compactWidth` the moment panel leaves the side: a summary of it
/// rides over the charts with the rail, its details a click away, and the
/// charts take the whole width.
struct HistoryView: View {
    static let compactWidth: CGFloat = 760
    private static let panelWidth: CGFloat = 310
    /// The time axis labels' font, for measuring them.
    private static let axisFont = NSFont.systemFont(ofSize: 10.5)

    @Environment(AppModel.self) private var model
    @AppStorage("historyRange") private var range: HistoryRange = .hour
    /// Spread the graphs from the first record in the range to the last.
    @AppStorage("historyFitsRecording") private var fitsRecording = false
    @State private var scrubber = HistoryScrubber()
    @State private var points: [HistoryPoint]?
    @State private var domain = Date.now.addingTimeInterval(-HistoryRange.hour.seconds)...Date.now
    /// Seconds each graph point averages.
    @State private var bucket = FlightRecorder.span
    @State private var earliest: Date?
    /// The first and last records within the range; nil while it has none.
    @State private var recordedSpan: ClosedRange<Date>?
    /// Whether those records begin well inside the range, after an empty stretch.
    @State private var startsLate = false
    /// Seconds recorded within the range, gaps left out.
    @State private var recorded: TimeInterval = 0
    @State private var fileSize: Int64 = 0
    /// The page's width: it picks the layout and how often the axes are labelled.
    @State private var width: CGFloat = 0

    private struct LoadKey: Equatable {
        let range: HistoryRange
        let fits: Bool
    }

    private var compact: Bool { width > 0 && width < Self.compactWidth }

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
            if !compact {
                // In a scroll view of its own, so it sits under the toolbar like the charts.
                ScrollView {
                    HistoryMomentPanel(scrubber: scrubber, points: points ?? [], bucket: bucket)
                        .padding([.top, .bottom, .trailing], 20)
                }
                .frame(width: Self.panelWidth)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
            // The controls move under the title, then the toggle under the
            // range, as the window narrows.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    title
                    Spacer(minLength: 0)
                    fitToggle
                    rangePicker
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    HStack(spacing: 12) {
                        rangePicker
                        fitToggle
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    rangePicker
                    fitToggle
                }
            }
            // One line: in a narrow window the cadence and retention move to the tooltip.
            ViewThatFits(in: .horizontal) {
                recording(status).fixedSize()
                recording(shortStatus)
            }
            .font(.callout)
            .help(recordedLabel + status)
        }
    }

    private func recording(_ status: String) -> Text {
        Text(recordedLabel).foregroundStyle(.primary).fontWeight(.medium) + Text(status).foregroundStyle(.secondary)
    }

    private var title: some View {
        Text("History").font(.largeTitle.weight(.semibold)).fixedSize()
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Spreads the graphs from the first record in the range to the last.
    /// A checkbox, so whether it's on reads at a glance; it's offered
    /// whenever the range has records, and never stretches the data.
    private var fitToggle: some View {
        Toggle("Fit to recorded data", isOn: Binding(get: { fitsRecording && recordedSpan != nil }, set: { fitsRecording = $0 }))
            .toggleStyle(.checkbox)
            .fixedSize()
            .disabled(recordedSpan == nil)
            .help(fitHelp)
    }

    /// What fitting does here, or why it can't.
    private var fitHelp: String {
        guard model.recorder != nil else { return "There's no recording to fit: it couldn't be opened." }
        guard let recordedSpan else { return "Nothing is recorded in \(range.phrase) yet, so there's nothing to fit the graphs to." }
        guard startsLate else {
            return "Spread the graphs from the first record to the last. The recording already spans \(range.phrase), so this changes little."
        }
        return "Spread the graphs from the first record in \(range.phrase), at \(Self.clock(recordedSpan.lowerBound)), "
            + "to the latest, instead of over all of \(range.phrase)."
    }

    /// "6:51 AM", or "Mon 6:51 AM" before today.
    private static func clock(_ time: Date) -> String {
        time.formatted(Calendar.current.isDateInToday(time) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
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
                                 ticks: axis.ticks, timeLabels: axis.labels, scrubber: scrubber)
            }
        }
    }

    /// The timeline over the charts, once there's something to pick from,
    /// and in a narrow window the moment's summary above it.
    @ViewBuilder private var rail: some View {
        if let points, !points.isEmpty, model.recorder != nil {
            VStack(alignment: .leading, spacing: 10) {
                if compact {
                    HistoryMomentSummary(scrubber: scrubber, points: points, bucket: bucket)
                }
                HistoryRail(scrubber: scrubber, points: points, domain: domain, bucket: bucket)
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
            // Covers the charts as they scroll under the pinned rail.
            .background(.background)
        }
    }

    /// Where the time axis is labelled: the range's own steps, or round
    /// steps for a fitted span, spread out further when the plots are too
    /// narrow for that many labels.
    private var timeAxis: (ticks: [Date], labels: Date.FormatStyle) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        var step = range.tickStep
        var labels = range.timeLabels
        if span < range.seconds - 1 {
            step = GraphMath.timeTickStep(for: span)
            labels = step < 60 ? .dateTime.hour().minute().second()
                : step >= 86_400 ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute()
        }
        // The charts' column, less the page's and the cards' padding and a scroll bar.
        let plot = (compact ? width : width - Self.panelWidth) - 40 - 28 - 16
        let widest = GraphMath.timeTicks(in: domain, step: step).map {
            ($0.formatted(labels) as NSString).size(withAttributes: [.font: Self.axisFont]).width
        }.max() ?? 0
        return (GraphMath.timeTicks(in: domain, step: step, width: Double(plot), labelWidth: Double(ceil(widest))), labels)
    }

    /// How much of the range is recorded: "17 min recorded since 6:51 AM".
    private var recordedLabel: String {
        guard let recordedSpan, recorded > 0 else { return "" }
        guard startsLate else { return "\(Format.roughDuration(recorded)) recorded in \(range.phrase)" }
        return "\(Format.roughDuration(recorded)) recorded since \(Self.clock(recordedSpan.lowerBound))"
    }

    /// The rest of the line under the title, after `recordedLabel`.
    private var status: String {
        var parts = ["every \(Int(FlightRecorder.span)) s while OpenTaskManager runs, kept for 7 days"]
        if fileSize > 0 { parts.append(Format.bytes(UInt64(fileSize)) + " on disk") }
        let text = parts.joined(separator: " · ")
        return recordedLabel.isEmpty ? "Recorded " + text : " · " + text
    }

    /// `status` for a narrow window: just the size on disk.
    private var shortStatus: String {
        guard fileSize > 0 else { return "" }
        let size = Format.bytes(UInt64(fileSize)) + " on disk"
        return recordedLabel.isEmpty ? size : " · " + size
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
        let start = end.addingTimeInterval(-range.seconds)
        let first = try? await recorder.earliest()
        let span = try? await recorder.recordedSpan(from: start, to: end)
        let shown = GraphMath.historyDomain(range: range.seconds, end: end, recorded: span, fit: fitsRecording, record: FlightRecorder.span)
        let step = FlightRecorder.bucket(for: shown.upperBound.timeIntervalSince(shown.lowerBound))
        let loaded = (try? await recorder.points(from: shown.lowerBound, to: shown.upperBound, bucket: step)) ?? []
        recorded = (try? await recorder.recordedSeconds(from: start, to: end)) ?? 0
        earliest = first
        recordedSpan = span
        startsLate = span.map { GraphMath.recordingStartsLate(range: range.seconds, end: end, recorded: $0) } ?? false
        fileSize = recorder.fileSize
        bucket = step
        domain = shown
        points = loaded
        // A pinned moment that has slid out of the range goes back to the latest.
        if let pinned = scrubber.pinned, !domain.contains(pinned) { scrubber.pinned = nil }
    }
}
