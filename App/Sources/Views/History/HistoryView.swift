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

    /// The range as the coverage line starts: "Last hour".
    var title: String {
        switch self {
        case .hour: "Last hour"
        case .sixHours: "Last 6 hours"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
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

/// What's picked on the History page's timeline. A click or drag on a graph
/// pins a moment, and it stays when the pointer leaves; hovering previews
/// another moment (or names the gap under the pointer) without moving the
/// pin. Playback moves a playhead of its own, which stays where it paused;
/// dragging along the rail moves the playhead while there is one, and pins
/// a moment otherwise. A session being marked and a saved session picked are
/// shaded on the charts and the rail. Only the markers, the rail and the side
/// panel read it, so neither the pointer nor playback redraws the charts.
@Observable
@MainActor
final class HistoryScrubber {
    /// A moment a click or drag picked; nil follows playback, else the latest.
    var pinned: Date?
    /// The moment under the pointer while it's over a graph or the rail.
    var hovered: Date?
    /// The stretch with nothing recorded under the pointer, in place of a moment.
    var hoveredGap: HistoryGap?
    /// Where playback has reached: it moves while playback plays and stays
    /// where it paused; nil when there's no playback to go back to.
    var playhead: Date?
    /// Set while playback moves the playhead.
    var isPlaying = false
    /// A session being marked.
    var draft: HistorySessionDraft?
    /// The saved session picked on the rail or from the Recordings menu.
    var session: RecordingSession?
    /// The gap picked from the gaps menu, outlined on the rail and the
    /// charts; a moment pinned elsewhere lets it go.
    var selectedGap: HistoryGap?
    /// The event picked on the rail or from the events menu.
    var selectedEvent: HistoryEvent?
    /// Two stretches being compared.
    var compare: HistoryCompareDraft?
    /// Showing a recording file, whose last moment is its end rather than the latest.
    var showsFile = false

    /// What the moment shown is called when nothing is pinned or playing.
    var endName: String { showsFile ? "End" : "Latest" }

    /// Which moment the side panel shows: the preview, else the pinned
    /// moment, else the playhead, else the latest.
    var focus: HistoryFocus {
        HistoryFocus(hovered: hovered, pinned: pinned, playhead: playhead, isPlaying: isPlaying)
    }

    /// The moment a session is marked from or to: the pinned one, else the playhead's.
    var picked: Date? { pinned ?? playhead }

    /// The point the moment panel shows, among `points`.
    func point(in points: [HistoryPoint]) -> HistoryPoint? {
        focus.time.flatMap { HistoryPoint.nearest(to: $0, in: points) } ?? points.last
    }

    /// Previews `moment`, or names `gap`, under the pointer. Each is set only
    /// when it changes: every set redraws the markers, the rail and the panel.
    func hover(_ moment: Date?, gap: HistoryGap? = nil) {
        if hovered != moment { hovered = moment }
        if hoveredGap != gap { hoveredGap = gap }
    }

    /// Pins `moment`, when it's another, letting a picked gap go.
    func pin(_ moment: Date?) {
        if pinned != moment { pinned = moment }
        if selectedGap != nil { selectedGap = nil }
    }

    /// The stretch the charts and the rail shade: the session being marked
    /// (open at the end until its end is picked), else the one picked.
    var marked: (start: Date, end: Date?)? {
        if let draft { return (draft.start, draft.end) }
        return session.map { ($0.start, $0.end) }
    }

    /// Forgets everything picked, for another recording.
    func reset() {
        pinned = nil
        hovered = nil
        hoveredGap = nil
        playhead = nil
        draft = nil
        session = nil
        selectedGap = nil
        selectedEvent = nil
        compare = nil
    }
}

/// A session being marked: the moments picked for its ends, in either order.
struct HistorySessionDraft: Equatable {
    /// The moment marked first.
    var from: Date
    /// The moment marked second, once picked.
    var to: Date?
    /// Seconds each graph point averaged when it was marked.
    let bucket: TimeInterval

    /// Where the session starts: the beginning of the stretch the earlier
    /// moment's point averages, so that point's records are in it.
    var start: Date { min(from, to ?? from).addingTimeInterval(-bucket) }
    /// Where it ends: the later moment, once both are picked.
    var end: Date? { to.map { max(from, $0) } }
}

/// The flight recorder's history: what the Mac was doing over the last hour
/// to week, with the busiest apps at any moment picked on the graphs. Or a
/// recording file opened read-only, shown the same way under a banner.
///
/// The page reads the recording when it opens, when the range changes and
/// once per graph point after that (a file, once). It never follows the
/// sampling tick.
///
/// Below `compactWidth` the moment panel leaves the side: a summary of it
/// rides over the charts with the rail, its details a click away, and the
/// charts take the whole width.
struct HistoryView: View {
    static let compactWidth: CGFloat = 760
    private static let panelWidth: CGFloat = 310
    /// The time axis labels' font, for measuring them.
    private static let axisFont = NSFont.systemFont(ofSize: 11)

    @Environment(AppModel.self) private var model
    @AppStorage("historyRange") private var range: HistoryRange = .hour
    /// Spread the graphs from the first record in the range to the last.
    @AppStorage("historyFitsRecording") private var fitsRecording = false
    @State private var scrubber = HistoryScrubber()
    @State private var player = HistoryPlayer()
    private let store = HistoryRecordingStore.shared
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
    /// The stretches within the range with nothing recorded, oldest first.
    @State private var gaps: [HistoryGap] = []
    /// What happened within the range, oldest first.
    @State private var events: [HistoryEvent] = []
    @State private var fileSize: Int64 = 0
    /// The page's width: it picks the layout and how often the axes are labelled.
    @State private var width: CGFloat = 0

    private struct LoadKey: Equatable {
        let range: HistoryRange
        let fits: Bool
        /// The recording file on show; nil for the live history.
        let recording: OpenedRecording.ID?
    }

    private var compact: Bool { width > 0 && width < Self.compactWidth }

    /// The recording file on show, or nil for the live history.
    private var opened: OpenedRecording? { store.opened }

    /// What the page reads: the opened file, else the live recorder.
    private var source: FlightRecorder? { opened?.recorder ?? model.recorder }

    var body: some View {
        VStack(spacing: 0) {
            if let opened {
                HistoryRecordingBanner(recording: opened, store: store)
            }
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
                        HistoryMomentPanel(scrubber: scrubber, player: player, points: points ?? [], bucket: bucket, recorder: source,
                                           events: events)
                            .padding([.top, .bottom, .trailing], 20)
                    }
                    .frame(width: Self.panelWidth)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .background {
            HistoryReplayReporter(player: player, store: store, showsFile: opened != nil)
            HistoryOpeningFocus()
        }
        .toolbar {
            ToolbarItem {
                HistoryRecordingsMenu(store: store, scrubber: scrubber, recorder: model.recorder, domain: domain, show: show)
            }
            ToolbarItem {
                Button {
                    Task { await export() }
                } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .help("Save every record in this range as a CSV file")
                .disabled(source == nil)
            }
        }
        .task(id: LoadKey(range: range, fits: fitsRecording, recording: opened?.id)) {
            scrubber.showsFile = opened != nil
            await load()
            // A recording file never changes; the live history gains a point every `bucket` seconds.
            guard opened == nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(bucket))
                await load()
            }
        }
        .onChange(of: opened?.id) {
            player.pause()
            scrubber.reset()
        }
        .onDisappear { player.pause() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if opened != nil {
                // A recording file has one span: no range to pick or fit.
                title
            } else {
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
            }
            // One line: in a narrow window the cadence and the size move to the tooltip.
            ViewThatFits(in: .horizontal) {
                coverage(tail: status)
                coverage(tail: shortStatus)
                coverage(tail: "")
            }
            .font(.callout)
            .help(coverageHelp)
        }
    }

    /// The span shown and how much of it was sampled, then its gaps and
    /// events, counted, each listed a click away, then `tail`.
    private func coverage(tail: String) -> some View {
        HStack(spacing: 5) {
            Text(coverageLabel).fontWeight(.medium).fixedSize()
            if let points, !points.isEmpty {
                Self.separator
                if gaps.isEmpty {
                    Text("no gaps").foregroundStyle(.secondaryText).fixedSize()
                } else {
                    HistoryGapsMenu(gaps: gaps, points: points, bucket: bucket, scrubber: scrubber)
                }
                if !events.isEmpty {
                    Self.separator
                    HistoryEventsMenu(events: events, points: points, bucket: bucket, scrubber: scrubber, player: player)
                }
            }
            if !tail.isEmpty {
                Self.separator
                Text(tail).foregroundStyle(.secondaryText).fixedSize()
            }
        }
    }

    private static var separator: some View {
        Text("·").foregroundStyle(.secondaryText)
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
        if source == nil {
            ContentUnavailableView("History isn't available", systemImage: "exclamationmark.triangle",
                                   description: Text("The recording at \(FlightRecorder.defaultURL.path) couldn't be opened."))
        } else if let points, points.isEmpty {
            if opened != nil {
                ContentUnavailableView("Nothing in this recording", systemImage: "waveform.slash",
                                       description: Text("The session it was saved from has no records."))
                    .padding(.top, 60)
            } else {
                ContentUnavailableView("Collecting history", systemImage: "clock.arrow.circlepath",
                                       description: Text("A record is written every \(Int(FlightRecorder.span)) seconds while OpenTaskManager runs."))
                    .padding(.top, 60)
            }
        } else if let points {
            let axis = timeAxis
            let gapMarks = HistoryGapMarks(gaps: gaps, points: points, bucket: bucket, domain: domain, plotWidth: plotWidth)
            HistoryComparisonSlot(scrubber: scrubber, recorder: source, bucket: bucket, revision: points.last?.time)
            ForEach(HistoryChartSpec.all(for: points)) { spec in
                HistoryChartCard(spec: spec, points: points, bucket: bucket, domain: domain, earliest: earliest, gaps: gapMarks,
                                 ticks: axis.ticks, timeLabels: axis.labels, scrubber: scrubber)
            }
            HistoryHardwareSection(recorder: source, points: points, bucket: bucket, domain: domain, earliest: earliest,
                                   isFile: opened != nil, gaps: gapMarks, ticks: axis.ticks, timeLabels: axis.labels, scrubber: scrubber)
        }
    }

    /// The charts' plot width: their column, less the page's and the cards' padding and a scroll bar.
    private var plotWidth: CGFloat {
        (compact ? width : width - Self.panelWidth) - 40 - 28 - 16
    }

    /// The timeline over the charts, once there's something to pick from,
    /// and in a narrow window the moment's summary above it.
    @ViewBuilder private var rail: some View {
        if let points, !points.isEmpty, source != nil {
            VStack(alignment: .leading, spacing: 10) {
                if compact {
                    HistoryMomentSummary(scrubber: scrubber, player: player, points: points, bucket: bucket, recorder: source,
                                         events: events)
                }
                // Sessions are marked in the live recording; a file is read-only.
                HistoryRail(scrubber: scrubber, player: player, store: store, recorder: opened == nil ? model.recorder : nil,
                            points: points, gaps: gaps, events: events, domain: domain, bucket: bucket)
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
        if opened != nil || span < range.seconds - 1 {
            step = GraphMath.timeTickStep(for: span)
            labels = step < 60 ? .dateTime.hour().minute().second()
                : step >= 86_400 ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute()
        }
        let plot = plotWidth
        let widest = GraphMath.timeTicks(in: domain, step: step).map {
            ($0.formatted(labels) as NSString).size(withAttributes: [.font: Self.axisFont]).width
        }.max() ?? 0
        return (GraphMath.timeTicks(in: domain, step: step, width: Double(plot), labelWidth: Double(ceil(widest))), labels)
    }

    /// Seconds the graphs span.
    private var shownSpan: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }

    /// Whether the graphs are fitted to less than the whole range.
    private var fitted: Bool { opened == nil && shownSpan < range.seconds - 1 }

    /// The span shown and how much of it holds records: "Last hour · 32 min
    /// sampled", "41 min span · 32 min sampled" fitted, "20 min span · 11 min
    /// sampled" for a file.
    private var coverageLabel: String {
        guard recordedSpan != nil, recorded > 0 else {
            return opened == nil ? "Nothing recorded in \(range.phrase) yet" : "Nothing recorded"
        }
        guard opened == nil, !fitted else { return HistoryInterval.coverage(span: shownSpan, sampled: recorded) }
        let since = startsLate ? recordedSpan.map { " since \(Self.clock($0.lowerBound))" } ?? "" : ""
        return "\(range.title) · \(Format.roughDuration(recorded)) sampled\(since)"
    }

    /// The end of the coverage line: how often records are written, and the size on disk.
    private var status: String {
        var parts = [opened == nil ? "a record every \(Int(FlightRecorder.span)) s while OpenTaskManager runs, kept 7 days"
            : "a record every \(Int(FlightRecorder.span)) s"]
        if !shortStatus.isEmpty { parts.append(shortStatus) }
        return parts.joined(separator: " · ")
    }

    /// `status` for a narrow window: just the size on disk.
    private var shortStatus: String {
        guard fileSize > 0 else { return "" }
        return Format.bytes(UInt64(fileSize)) + (opened == nil ? " on disk" : " file")
    }

    /// The coverage line spelled out, with what a narrow window leaves off it.
    private var coverageHelp: String {
        var text = "The graphs span \(fitted || opened != nil ? Format.roughDuration(shownSpan) : range.phrase)"
        if recorded > 0 { text += ", of which \(Format.roughDuration(recorded)) was recorded" }
        text += ". Gaps, where the app wasn't running, the Mac slept or updates were paused, are hatched on the graphs "
            + "and the timeline and left out of every figure."
        if !events.isEmpty { text += " Events are marked over the timeline." }
        return text + " Recorded " + status + "."
    }

    /// Picks a saved session, switching to the shortest range that reaches back to it.
    private func show(_ session: RecordingSession) {
        let reach = Date.now.timeIntervalSince(session.start)
        range = HistoryRange.allCases.first { $0.seconds >= reach } ?? .week
        scrubber.draft = nil
        scrubber.session = session
    }

    /// Saves the records in the range shown, at full resolution, as CSV.
    private func export() async {
        guard let source else { return }
        let records = (try? await source.records(from: domain.lowerBound, to: opened == nil ? .now : domain.upperBound)) ?? []
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = opened.map { "\($0.title).csv" }
            ?? "OpenTaskManager history \(Date.now.formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryRecord.csv(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func load() async {
        if let opened {
            await load(opened)
        } else if let recorder = model.recorder {
            await loadLive(recorder)
        }
    }

    /// The whole of an opened recording file.
    private func load(_ opened: OpenedRecording) async {
        let recorder = opened.recorder
        let session = opened.session
        let shown = session.start...max(session.end, session.start.addingTimeInterval(60))
        let step = FlightRecorder.bucket(for: shown.upperBound.timeIntervalSince(shown.lowerBound))
        let loaded = (try? await recorder.points(from: shown.lowerBound, to: shown.upperBound, bucket: step)) ?? []
        let seconds = (try? await recorder.recordedSeconds(from: shown.lowerBound, to: shown.upperBound)) ?? 0
        let span = try? await recorder.recordedSpan(from: shown.lowerBound, to: shown.upperBound)
        let happened = (try? await recorder.events(from: shown.lowerBound, to: shown.upperBound)) ?? []
        guard !Task.isCancelled else { return }
        recorded = seconds
        earliest = nil
        recordedSpan = span
        startsLate = false
        fileSize = recorder.fileSize
        bucket = step
        domain = shown
        points = loaded
        gaps = HistoryGap.gaps(in: loaded, bucket: step, within: shown)
        if events != happened { events = happened }
        player.points = loaded
        if let speed = store.takeLaunchSpeed() {
            player.speed = speed
            player.play(scrubber)
        }
    }

    /// The range shown of the live recording, and its saved sessions.
    private func loadLive(_ recorder: FlightRecorder) async {
        let end = Date.now
        let start = end.addingTimeInterval(-range.seconds)
        let first = try? await recorder.earliest()
        let span = try? await recorder.recordedSpan(from: start, to: end)
        let shown = GraphMath.historyDomain(range: range.seconds, end: end, recorded: span, fit: fitsRecording, record: FlightRecorder.span)
        let step = FlightRecorder.bucket(for: shown.upperBound.timeIntervalSince(shown.lowerBound))
        let loaded = (try? await recorder.points(from: shown.lowerBound, to: shown.upperBound, bucket: step)) ?? []
        let seconds = (try? await recorder.recordedSeconds(from: start, to: end)) ?? 0
        let sessions = (try? await recorder.sessions()) ?? []
        let happened = (try? await recorder.events(from: shown.lowerBound, to: shown.upperBound)) ?? []
        // The range changed or a file opened meanwhile: this load is stale.
        guard !Task.isCancelled else { return }
        if events != happened { events = happened }
        recorded = seconds
        earliest = first
        recordedSpan = span
        startsLate = span.map { GraphMath.recordingStartsLate(range: range.seconds, end: end, recorded: $0) } ?? false
        fileSize = recorder.fileSize
        bucket = step
        domain = shown
        points = loaded
        gaps = HistoryGap.gaps(in: loaded, bucket: step, within: shown, since: first)
        player.points = loaded
        store.update(sessions)
        // A pinned moment or playhead that has slid out of the range goes back to the latest.
        if let pinned = scrubber.pinned, !domain.contains(pinned) { scrubber.pinned = nil }
        if let playhead = scrubber.playhead, !domain.contains(playhead) { player.stop(scrubber) }
        if let picked = scrubber.session, !sessions.contains(picked) { scrubber.session = nil }
        if let gap = scrubber.selectedGap, !gaps.contains(gap) { scrubber.selectedGap = nil }
    }
}
