import OTMKit
import SwiftUI

struct RecentProcessesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = LaunchArgument.string("openRecentlyEndedProcess") ?? ""
    @State private var didOpenRequestedProcess = false
    @State private var selection: ProcessIdentity?
    /// A selection stays inspectable after its row expires. It never becomes
    /// a request to inspect or control the process now holding this PID.
    @State private var selected: RecentlyEndedProcess?

    private var rows: [RecentlyEndedProcess] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.recentProcesses.entries.filter {
            query.isEmpty || [$0.process.name, String($0.process.pid), $0.process.userName, $0.process.executablePath ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    Divider()
                    RecentProcessDetail(entry: selected, isRetained: model.recentProcesses.entries.contains { $0.id == selected.id })
                        .id(selected.id)
                        .frame(width: 320)
                }
            }
            Divider()
            HStack {
                Text("\(rows.count) shown · \(model.recentProcesses.entries.count) retained · latest first")
                Spacer()
                if model.isPaused { Text("Sampling paused").foregroundStyle(.orange) }
            }
            .font(.explanation).foregroundStyle(.secondaryText).padding(12)
        }
        .frame(width: 960, height: 600)
        .onAppear(perform: openRequestedProcess)
        .onChange(of: model.recentProcesses.entries) { openRequestedProcess() }
        .onChange(of: selection) {
            if let selection, let entry = model.recentProcesses.entries.first(where: { $0.id == selection }) { selected = entry }
        }
        .samplingDemand(.window)
        .samplingDemand(.restrictedProcesses)
    }

    /// A real observed exit can be selected once for background captures.
    private func openRequestedProcess() {
        guard !didOpenRequestedProcess, let name = LaunchArgument.string("openRecentlyEndedProcess"),
              let entry = model.recentProcesses.entries.first(where: { $0.process.name.localizedCaseInsensitiveContains(name) }) else { return }
        didOpenRequestedProcess = true
        selection = entry.id
        selected = entry
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ended recently").font(.title2.weight(.semibold))
                Spacer()
                TextField("Name, PID, user or path", text: $query).textFieldStyle(.roundedBorder).frame(width: 250)
                Button("Clear") {
                    model.recentProcesses.clear()
                    selection = nil
                    selected = nil
                }
                .disabled(model.recentProcesses.entries.isEmpty && selected == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("No longer seen between consecutive samples. Last readings stay here for about a minute, up to 200 processes. "
                 + "Pauses, sampling gaps and scope changes aren't counted as exits.")
                .font(.callout).foregroundStyle(.secondaryText)
        }
        .padding(16)
    }

    private var list: some View {
        VStack(spacing: 0) {
            endedTable.fitsTableToRows(rows.count)
            Spacer(minLength: 0)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No recently ended processes" : "No matches", systemImage: "clock.arrow.circlepath",
                                       description: Text(query.isEmpty
                                           ? "Only processes seen while sampling can appear here. "
                                               + "Processes that start and end between samples may be missed."
                                           : "Try a different name, PID, user or path."))
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
    }

    private var endedTable: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { entry in Text(entry.process.name).lineLimit(1).help(entry.process.executablePath ?? entry.process.name) }
                .width(min: 140, ideal: 190)
            TableColumn("PID") { entry in Text(String(entry.process.pid)).monospacedDigit() }.width(55)
            TableColumn("Not seen by") { entry in Text(entry.missingAt, format: .dateTime.hour().minute().second()).monospacedDigit() }
                .width(90)
            TableColumn("Last CPU") { entry in Text(model.cpuScale.format(entry.process.cpuPercent)).monospacedDigit() }.width(62)
            TableColumn("Last memory") { entry in Text(Format.bytes(entry.process.memory)).monospacedDigit() }.width(82)
        }
        .foregroundStyle(.secondaryText)
    }
}

private struct RecentProcessDetail: View {
    @Environment(AppModel.self) private var model
    @CurrentPage private var page
    @Environment(\.dismiss) private var dismiss
    let entry: RecentlyEndedProcess
    let isRetained: Bool
    @State private var ending: ProcessEnding?
    @State private var hasRecordedHistory = false
    @State private var evidenceError: String?
    @State private var checks = 0

    private var isObservedAgain: Bool { entry.id.find(in: model.snapshot?.processes ?? []) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.process.name).font(.headline).textSelection(.enabled)
                Text("PID \(entry.process.pid) · \(entry.process.userName)").font(.callout).foregroundStyle(.secondaryText)
                if isObservedAgain {
                    Text("Observed again. The earlier disappearance was temporary; the readings below are the previous snapshot.")
                        .font(.callout).foregroundStyle(.secondaryText)
                } else if !isRetained {
                    Text("This entry has left the recent list. Its selected snapshot remains here until you close or clear it.")
                        .font(.explanation).foregroundStyle(.secondaryText)
                }
                Group {
                    fact("Last observed", entry.lastSeen.formatted(date: .abbreviated, time: .standard))
                    fact("Not seen by", entry.missingAt.formatted(date: .abbreviated, time: .standard))
                    fact("Started", entry.id.startTime?.formatted(date: .abbreviated, time: .standard) ?? "Not reported")
                    HStack(alignment: .top, spacing: 24) {
                        fact("Last CPU", model.cpuScale.format(entry.process.cpuPercent))
                        fact("Last memory", Format.bytes(entry.process.memory))
                    }
                    if let path = entry.process.executablePath { fact("Executable", path) }
                }
                Divider()
                if isObservedAgain {
                    Text("No end is inferred while this identity is being observed again.")
                        .font(.explanation).foregroundStyle(.secondaryText)
                } else if let ending {
                    HistoryProcessEnding(ending: ending)
                    if ending.evidenceCut == true {
                        Text("The recorded evidence query reached its limit; further evidence may exist.").font(.explanation)
                    }
                } else {
                    ProgressView("Checking ending evidence…").controlSize(.small)
                }
                if let evidenceError { Text(evidenceError).font(.explanation).foregroundStyle(.secondaryText) }
                Text("These are last observed readings. Disappearance alone doesn't establish a crash or an exact exit time. "
                     + "No live process controls are available for this snapshot.")
                    .font(.explanation).foregroundStyle(.secondaryText)
                HStack {
                    Button("Check again") { checks += 1 }.disabled(ending == nil || isObservedAgain)
                    if hasRecordedHistory {
                        Button("Show History") {
                            HistoryProcessStore.shared.show(entry.process.name, identity: entry.id)
                            page = .history
                            dismiss()
                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .task(id: checks) { await loadEnding() }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.explanation).foregroundStyle(.secondaryText)
            Text(value).font(.callout).monospacedDigit().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No file or recorder reads happen on sampling ticks, only selection
    /// and the user's Check again. Always query the frozen identity.
    private func loadEnding() async {
        guard !isObservedAgain else { return }
        var lifetime = entry.lifetime
        var recorded = false
        var failure: String?
        var result: ProcessEnding?
        if let recorder = model.recorder {
            do {
                if let stored = try await recorder.processLifetime(entry.id) {
                    lifetime.jobLabel = stored.jobLabel
                    recorded = true
                }
                result = try await recorder.processEnding(lifetime, limit: 200)
            } catch {
                failure = "Recorded ending evidence couldn't be read. Diagnostic reports were checked separately."
            }
        }
        if result == nil {
            let frozen = lifetime
            result = await Task.detached(priority: .utility) {
                ProcessEnding(lifetime: frozen, reports: ProcessDiagnosticReports.read(for: frozen))
            }.value
        }
        guard !Task.isCancelled else { return }
        hasRecordedHistory = recorded
        evidenceError = failure
        ending = result
    }
}
