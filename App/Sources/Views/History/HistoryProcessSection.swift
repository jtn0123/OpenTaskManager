import OTMKit
import SwiftUI

/// The History page's process search: a card over the charts with a field
/// that finds the processes the recording saw in the range by name,
/// executable path, launchd label or bundle identifier, or PID. Each result
/// says when it ran within the range, its average and peak CPU and peak
/// memory, and whether it still runs; picking one charts its CPU, memory and
/// disk over the range under the card, marks its lifetime on the rail, and
/// puts its figures beside the pinned moment's. Short runs, idle processes
/// counted by kind rather than kept one by one, list how many and when.
///
/// The search and the picked process's points are read when the query, the
/// pick, the range or a new graph point asks (`HistoryProcessStore`), never
/// per tick; nothing here reads the sampler's latest tick in its body.
struct HistoryProcessSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page: Page = .overview
    /// The opened file, else the live recording.
    let recorder: FlightRecorder?
    /// Showing a recording file, which keeps no process history.
    let isFile: Bool
    /// The page's points, which the charts' pointer snaps to.
    let points: [HistoryPoint]
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    let gaps: HistoryGapMarks
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber
    private let store = HistoryProcessStore.shared
    /// Results listed before "Show all".
    private static let listed = 6
    @State private var showsAll = false

    private struct SearchKey: Equatable {
        let query: String
        let requests: Int
        let recording: URL?
        let domain: ClosedRange<Date>
        let revision: Date?
    }

    private struct TrackKey: Equatable {
        let picked: ProcessIdentity?
        let recording: URL?
        let domain: ClosedRange<Date>
        let bucket: TimeInterval
        let revision: Date?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryPageScroll.spacing) {
            Card {
                header
                if isFile {
                    note("A recording file keeps the figures above, not each process's. Search the live history for processes.")
                } else if store.picked != nil {
                    if let track = store.track {
                        HistoryProcessSummary(track: track, onShowInProcesses: showInProcesses, onBack: store.unpick)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let results = store.results {
                    list(results)
                } else {
                    note("Find a process History saw in this range by name, executable, launchd label or PID, "
                        + "and chart its CPU, memory and disk.")
                }
            }
            if store.picked != nil, let track = store.track {
                HistoryProcessCharts(track: track, points: points, bucket: bucket, domain: domain, gaps: gaps, ticks: ticks,
                                     timeLabels: timeLabels, scrubber: scrubber)
            }
        }
        .task(id: SearchKey(query: store.query, requests: store.requests, recording: recorder?.url, domain: domain,
                            revision: points.last?.time)) {
            guard let recorder, !isFile else { return }
            // Waits for typing to pause; a key pressed meanwhile starts again.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.search(in: recorder, domain: domain, isRunning: isRunning)
        }
        .task(id: TrackKey(picked: store.picked, recording: recorder?.url, domain: domain, bucket: bucket, revision: points.last?.time)) {
            guard let recorder, !isFile else { return }
            await store.load(from: recorder, domain: domain, bucket: bucket, isRunning: isRunning)
        }
        .onChange(of: store.results?.query) { showsAll = false }
    }

    /// The title, the field, and how many were found.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("Processes", systemImage: "magnifyingglass")
                .font(.headline)
                .foregroundStyle(.secondaryText)
                .fixedSize()
            TextField("Search processes", text: Binding(get: { store.query }, set: { store.query = $0 }),
                      prompt: Text("Name, executable, launchd label or PID"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 300)
                .disabled(isFile || recorder == nil)
                .help("Search the processes History saw in this range. A whole number also finds that PID.")
            if !store.query.isEmpty {
                Button {
                    store.clear()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondaryText)
                .help("Clear the search")
            }
            Spacer(minLength: 0)
            if store.picked == nil, let results = store.results, !results.entries.isEmpty {
                Text(count(results))
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .fixedSize()
            }
        }
    }

    /// "3 found · 83 short runs", "latest 50 shown" when the search hit its limit.
    private func count(_ results: HistoryProcessStore.Results) -> String {
        var parts: [String] = []
        let found = results.matches.count
        if found > 0 { parts.append(found >= HistoryProcessStore.limit ? "latest \(found) shown" : "\(found) found") }
        let runs = results.shortRunCount
        if runs > 0 { parts.append("\(runs) short \(runs == 1 ? "run" : "runs")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func list(_ results: HistoryProcessStore.Results) -> some View {
        if results.entries.isEmpty {
            note("Nothing matching “\(results.query)” ran while History was recording in this range.")
        } else {
            let shown = showsAll ? results.entries : Array(results.entries.prefix(Self.listed))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { entry in
                    switch entry {
                    case .lifetime(let match):
                        HistoryProcessRow(match: match, domain: domain, isRunning: results.running.contains(match.id)) {
                            store.pick(match)
                        }
                    case .shortRuns(let runs):
                        HistoryShortRunsRow(runs: runs)
                    }
                }
            }
            if results.entries.count > shown.count {
                Button("Show all \(results.entries.count)") { showsAll = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.explanation)
            .foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether `identity` is the process running now with its PID. Read in
    /// the loads, never the body, so a tick doesn't redraw the section.
    private func isRunning(_ identity: ProcessIdentity) -> Bool {
        !isFile && model.processIdentityByPID[identity.pid] == identity
    }

    /// Selects the picked process on the Processes page, if it's still the one running.
    private func showInProcesses() {
        guard let identity = store.track?.lifetime.identity, isRunning(identity) else { return }
        model.requestedProcess = identity.pid
        page = .processes
    }
}

/// One lifetime found: its name, PID and label, whether it still runs, when
/// it ran within the range and its figures there. A click picks it.
private struct HistoryProcessRow: View {
    @Environment(AppModel.self) private var model
    let match: ProcessHistoryMatch
    let domain: ClosedRange<Date>
    let isRunning: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let lifetime = match.lifetime
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lifetime.name).font(.tableText.weight(.semibold)).lineLimit(1)
                    Text("PID \(String(lifetime.identity.pid))").font(.metadata).monospacedDigit().foregroundStyle(.secondaryText)
                        .fixedSize()
                    if let label = lifetime.label {
                        Text(label).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    HistoryProcessState(lifetime: lifetime, isRunning: isRunning)
                }
                Text(details(lifetime))
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(lifetime.path.map { "\($0)\n\nClick to chart it over the range." } ?? "Click to chart it over the range.")
    }

    /// "10:02 – 10:42 AM · 40 min · CPU avg 3.2%, peak 45% · Memory peak 1.2 GB".
    private func details(_ lifetime: ProcessLifetime) -> String {
        let figures = HistoryProcessStyle.figures(match.summary, scale: model.cpuScale)
        guard let span = lifetime.span(within: domain, isRunning: isRunning, now: domain.upperBound) else { return figures }
        return HistoryProcessStyle.ran(lifetime, span: span, domain: domain) + " · " + figures
    }
}

/// A kind's short runs found: its name and executable, how many and when.
/// They have no PIDs or figures, so there's nothing to pick.
private struct HistoryShortRunsRow: View {
    let runs: ProcessHistoryShortRuns

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(runs.name).font(.tableText.weight(.semibold)).lineLimit(1)
                Text("×\(runs.count)").font(.metadata).monospacedDigit().foregroundStyle(.secondaryText).fixedSize()
                if let path = runs.path {
                    Text(path).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            Text(HistoryProcessStyle.shortRuns(runs))
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(HistoryProcessStyle.shortRunsHelp)
    }
}

/// "Running" in green, or when it ended or was last seen.
struct HistoryProcessState: View {
    let lifetime: ProcessLifetime
    let isRunning: Bool

    var body: some View {
        if isRunning {
            Label("Running", systemImage: "circle.fill")
                .labelStyle(HistoryProcessStateLabel())
                .font(.metadata.weight(.medium))
                .foregroundStyle(.green)
                .fixedSize()
                .help("Still running, as the same process (PID and start time)")
        } else {
            Text(HistoryProcessStyle.state(lifetime, isRunning: false))
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .monospacedDigit()
                .fixedSize()
                .help(lifetime.ended == nil
                    ? "History stopped watching it then: OpenTaskManager quit, or stopped showing other users' and system "
                        + "processes. It may have run on."
                    : "When History saw it end")
        }
    }
}

/// A small dot before the label's text.
private struct HistoryProcessStateLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

/// The picked lifetime over the card: back to the results, its name, PID
/// and state, where it runs from, when it ran within the range and its
/// figures there, and the key to how its charts draw idle, unrecorded and
/// not-running stretches.
private struct HistoryProcessSummary: View {
    @Environment(AppModel.self) private var model
    let track: HistoryProcessStore.Track
    let onShowInProcesses: () -> Void
    let onBack: () -> Void

    var body: some View {
        let lifetime = track.lifetime
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: onBack) {
                    Label("Results", systemImage: "chevron.left")
                }
                .controlSize(.small)
                .fixedSize()
                .help("Back to the processes found")
                Text(lifetime.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(String(lifetime.identity.pid))").font(.callout).monospacedDigit().foregroundStyle(.secondaryText).fixedSize()
                HistoryProcessState(lifetime: lifetime, isRunning: track.isRunning)
                Spacer(minLength: 0)
                if track.isRunning {
                    Button("Show in Processes", action: onShowInProcesses)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Select it on the Processes page")
                }
            }
            facts(lifetime)
            Text(figures)
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            HistoryProcessKeyRow()
        }
    }

    @ViewBuilder private func facts(_ lifetime: ProcessLifetime) -> some View {
        let parts = [lifetime.label, lifetime.user.isEmpty ? nil : lifetime.user].compactMap { $0 }
        if let path = lifetime.path {
            Text(path)
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        }
        Text(([ranLine] + parts).joined(separator: " · "))
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
            .lineLimit(2)
    }

    /// When it ran within the range.
    private var ranLine: String {
        guard let span = track.span else { return "Didn't run in this range" }
        let ran = HistoryProcessStyle.ran(track.lifetime, span: span, domain: track.domain)
        return HistoryProcessStyle.ranBefore(track.lifetime, domain: track.domain) ? ran : "Ran " + ran
    }

    /// Its figures over the part of the range it ran, and how many records kept them.
    private var figures: String {
        let summary = track.match.summary
        var line = HistoryProcessStyle.figures(summary, scale: model.cpuScale)
        if let read = summary.averageDiskRead, let write = summary.averageDiskWrite {
            line += " · Disk avg read \(HistoryProcessStyle.unbroken(Format.bytesPerSecond(read))), "
                + "write \(HistoryProcessStyle.unbroken(Format.bytesPerSecond(write)))"
        }
        if summary.records > 0 {
            let idle = summary.records - summary.stored
            line += idle > 0 ? " · kept in \(summary.stored) of \(summary.records) records, idle in the rest" : " · kept in every record"
        }
        return line
    }
}

/// How a process's charts draw what has no figures: idle (it ran, under the
/// keep thresholds), not recorded (a gap), and not running.
struct HistoryProcessKeyRow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            item("Idle, not stored", help: HistoryProcessStyle.idleHelp) {
                HistoryIdleSample()
            }
            item("Not recorded", help: "Gaps: the app wasn't running, the Mac slept, or updates were paused; or History wasn't "
                + "watching this process then (before its first sighting, or while an older build recorded).") {
                Canvas { context, size in
                    HistoryCoverage.drawGaps([CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)], in: context,
                                             dark: colorScheme == .dark)
                }
                .frame(width: 18, height: 11)
            }
            item("Not running", help: "Before it started or after it ended: dimmed, with no line.") {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HistoryProcessStyle.notRunning(dark: colorScheme == .dark))
                    .frame(width: 18, height: 11)
            }
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
    }

    private func item(_ name: String, help: String, @ViewBuilder sample: () -> some View) -> some View {
        HStack(spacing: 5) {
            sample()
            Text(name).fixedSize()
        }
        .help(help)
    }
}
