import AppKit
import OTMKit
import SwiftUI
import UniformTypeIdentifiers

/// The sheet loads only when its fixed window changes. It observes no sampler or graph clock.
struct IncidentView: View {
    let initialWindow: IncidentWindow
    let recorder: FlightRecorder?
    let fixture: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 0
    @State private var timeline: IncidentTimeline?
    @State private var error: String?
    @State private var includesPrivateDetails = false

    private var window: IncidentWindow {
        minutes == 0 ? initialWindow : IncidentWindow(at: initialWindow.midpoint, minutes: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Investigate incident").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(window.start.formatted(date: .abbreviated, time: .standard)) — \(window.end.formatted(date: .abbreviated, time: .standard))")
                .font(.metadata).monospacedDigit()
            Picker("Window", selection: $minutes) {
                Text("Original window").tag(0)
                ForEach(IncidentWindow.minuteChoices, id: \.self) { Text("±\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            if fixture { Text("Made-up fixture · nothing saved").font(.explanation).foregroundStyle(.secondaryText) }
            if let error { Text(error).font(.explanation).foregroundStyle(.secondaryText) }
            ScrollView {
                if let timeline {
                    VStack(alignment: .leading, spacing: 16) {
                        coverageSummary(timeline)
                        sequences(timeline)
                        ForEach(timeline.lanes, id: \.kind) { lane in laneView(lane, timeline: timeline) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if error == nil {
                    ProgressView("Reading incident evidence…").frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Toggle("Include home paths, user names and full remote addresses", isOn: $includesPrivateDetails)
                    .font(.metadata)
                Spacer()
                Button("Export Evidence…") { Task { await export() } }.disabled(timeline == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 720, maxWidth: 780, minHeight: 360, idealHeight: 620, maxHeight: 720)
        .task(id: window) {
            let requested = window
            timeline = nil
            error = nil
            do {
                let result: IncidentTimeline
                if fixture { result = IncidentFixture.timeline(requested) } else if let recorder {
                    result = try await recorder.incident(requested)
                } else { error = "Flight recorder unavailable; this window could not be read."; return }
                guard !Task.isCancelled, requested == window else { return }
                timeline = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func coverageSummary(_ timeline: IncidentTimeline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorder coverage").font(.headline)
            ForEach(timeline.lanes, id: \.kind) { lane in
                Text("\(lane.kind.rawValue): \(lane.domains.isEmpty ? lane.coverage.words : "see each launchd domain below")"
                     + (lane.cut ? " · lane cut" : ""))
                    .font(.metadata).foregroundStyle(.secondaryText)
            }
        }
    }

    private func sequences(_ timeline: IncidentTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Happened together").font(.headline)
            Text("These sequences describe observations together. They do not establish a cause.")
                .font(.explanation).foregroundStyle(.secondaryText)
            if timeline.sequences.isEmpty { Text("No sequence found in the loaded evidence.").font(.metadata) }
            ForEach(timeline.sequences) { sequence in
                DisclosureGroup(sequence.label) {
                    ForEach(sequence.evidence) { row in evidenceRow(row) }
                }
                .font(.tableText)
            }
        }
    }

    private func laneView(_ lane: IncidentLane, timeline: IncidentTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(lane.kind.rawValue).font(.headline)
            if lane.domains.isEmpty { coverage(lane.coverage) }
            ForEach(lane.domains.keys.sorted(), id: \.self) { domain in
                if let watched = lane.domains[domain] {
                    Text(domain).font(.tableText)
                    coverage(watched)
                }
            }
            if lane.cut { Text("Lane cut: first \(lane.rows.count) rows loaded; more evidence may exist.").font(.explanation) }
            Text(lane.note).font(.explanation).foregroundStyle(.secondaryText)
            if lane.rows.isEmpty { Text("No rows in the loaded evidence.").font(.tableText) }
            ForEach(lane.rows) { row in
                evidenceRow(row)
                if lane.kind == .processes, row.kind == "ended" || row.kind == "started" {
                    let linked = timeline.lanes.filter { $0.kind == .jobs || $0.kind == .sockets }
                        .flatMap(\.rows).filter { $0.lifetime == row.lifetime && row.lifetime != nil }
                    if !linked.isEmpty {
                        DisclosureGroup("Related observations for this lifetime (\(linked.count))") {
                            ForEach(linked) { linkedRow in evidenceRow(linkedRow) }
                        }
                        .font(.metadata).padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func coverage(_ value: IncidentCoverage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.words).font(.metadata).foregroundStyle(.secondaryText)
            if value.state == .partly {
                ForEach(value.spans) { span in
                    Text("\(value.inferred ? "Recording / sighting" : "Watched") "
                         + "\(span.start.formatted(date: .omitted, time: .standard)) — \(span.end.formatted(date: .omitted, time: .standard))")
                        .font(.metadata).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    private func evidenceRow(_ row: IncidentRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.time.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondaryText)
                Text(row.title).textSelection(.enabled)
                Spacer(minLength: 0)
                if row.lifetime != nil || row.job != nil || row.socket != nil || row.kind == "listener" {
                    Button("Inspect") { inspect(row) }.controlSize(.small).disabled(fixture)
                }
            }
            .font(.tableText)
            if !row.detail.isEmpty { Text(row.detail).font(.metadata).foregroundStyle(.secondaryText).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func inspect(_ row: IncidentRow) {
        dismiss()
        if let job = row.job {
            IncidentNavigation.shared.job = job
            PageSelection.shared.page = .startup
        } else if let socket = row.socket {
            IncidentNavigation.shared.socket = socket
            IncidentNavigation.shared.search = String(row.process?.pid ?? 0)
            PageSelection.shared.page = .connections
        } else if row.kind == "listener" {
            IncidentNavigation.shared.socket = nil
            IncidentNavigation.shared.search = String(row.port ?? 0)
            PageSelection.shared.page = .connections
        } else if let identity = row.process {
            IncidentNavigation.shared.revealsProcess = true
            HistoryRecordingStore.shared.connectionMoment = row.time
            HistoryProcessStore.shared.show(String(identity.pid), identity: identity)
        }
    }

    private func export() async {
        guard let timeline else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .json]
        panel.nameFieldStringValue = "Incident.md"
        panel.message = "Choose Markdown (.md) or JSON (.json). Both contain the same evidence and coverage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = IncidentExport(timeline, includesPrivateDetails: includesPrivateDetails)
        do {
            try await Task.detached(priority: .userInitiated) {
                let data = url.pathExtension.lowercased() == "json" ? try report.json() : Data(report.markdown().utf8)
                try data.write(to: url, options: .atomic)
            }.value
        } catch { self.error = "Evidence could not be saved: \(error.localizedDescription)" }
    }
}
