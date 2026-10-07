import OTMKit
import SwiftUI

struct ProcessInspectorView: View {
    @Environment(AppModel.self) private var model
    let pid: Int32

    @State private var details = Details()
    @State private var tab: Tab = .overview
    @State private var socketsOnly = false
    @State private var confirmingForceQuit = false

    struct Details {
        var arguments: ProcessArguments?
        var directory: String?
        var openFiles: [OpenFile]?
        var loaded = false
    }

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case environment = "Environment"
        case files = "Files & Ports"
    }

    var body: some View {
        if let process = model.process(pid) {
            VStack(alignment: .leading, spacing: 12) {
                header(process)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    switch tab {
                    case .overview: overview(process)
                    case .environment: environment
                    case .files: files
                    }
                }
                actions(process)
            }
            .padding(12)
            .task(id: pid) { await loadDetails() }
        }
    }

    // MARK: Sections

    private func header(_ process: ProcessSample) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: process, app: model.regularApps[process.pid]))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(for: process)).font(.headline).lineLimit(1)
                Text("PID \(process.pid) · \(process.userName) · \(process.state.rawValue)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func graphs(_ process: ProcessSample) -> some View {
        let history = model.processHistory[pid]?.values ?? []
        return VStack(alignment: .leading, spacing: 12) {
            GraphPanel(
                title: "CPU",
                trailing: model.cpuScale.format(process.cpuPercent),
                series: [GraphSeries(values: history.map { model.cpuScale.value($0.cpuPercent) }, color: Theme.cpu)],
                height: 80,
                minimumCeiling: model.cpuScale.relativeToSystem ? 2 : 10,
                axis: { Format.fixed($0, $0 < 10 ? 1 : 0) + "%" },
                capacity: AppModel.processHistoryCapacity - 2
            )
            GraphPanel(
                title: process.isRestricted ? "Memory (resident)" : "Memory",
                trailing: Format.bytes(process.memory),
                series: [GraphSeries(values: history.map { Double($0.memory) }, color: Theme.memory)],
                height: 80,
                minimumCeiling: 1_048_576,
                axis: { Format.bytes(UInt64(max($0, 0))) },
                axisUnits: .binaryBytes,
                capacity: AppModel.processHistoryCapacity - 2
            )
            if !process.isRestricted {
                HStack(spacing: 12) {
                    GraphPanel(
                        title: "Power",
                        trailing: process.powerWatts.map(Format.watts) ?? "—",
                        series: [GraphSeries(values: history.map(\.powerWatts), color: Theme.power)],
                        height: 60,
                        minimumCeiling: 0.5,
                        axis: Format.watts,
                        capacity: AppModel.processHistoryCapacity - 2
                    )
                    if process.gpuTime != nil {
                        GraphPanel(
                            title: "GPU",
                            trailing: Format.percent(process.gpuFraction ?? 0, digits: 1),
                            series: [GraphSeries(values: history.map(\.gpuFraction), color: Theme.gpu)],
                            height: 60,
                            minimumCeiling: 0.05,
                            maximumCeiling: 1,
                            axis: { Format.percent($0) },
                            capacity: AppModel.processHistoryCapacity - 2
                        )
                    }
                }
            }
        }
    }

    private func overview(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            graphs(process)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                FactRow(label: "CPU time", value: Format.cpuTime(process.cpuTime))
                FactRow(label: "Threads", value: process.threadCount > 0 ? String(process.threadCount) : "—")
                if !process.isRestricted {
                    FactRow(label: "Real memory", value: Format.bytes(process.residentMemory))
                    FactRow(label: "Power", value: process.powerWatts.map(Format.watts) ?? "—")
                    FactRow(label: "Disk read",
                            value: "\(Format.bytesPerSecond(process.diskReadRate)) · \(Format.bytes(process.diskReadTotal)) total")
                    FactRow(label: "Disk written",
                            value: "\(Format.bytesPerSecond(process.diskWriteRate)) · \(Format.bytes(process.diskWriteTotal)) total")
                    FactRow(label: "Wakeups", value: process.wakeupsPerSecond.map { Format.fixed($0, 0) + "/s" } ?? "—")
                    if let share = process.topTierShare {
                        FactRow(label: "On \(model.topology.tiers.first?.name ?? "fast") cores", value: Format.percent(share))
                    }
                }
                if let gpu = process.gpuTime {
                    FactRow(label: "GPU", value: "\(Format.percent(process.gpuFraction ?? 0, digits: 1)) · \(Format.cpuTime(gpu)) total")
                }
                FactRow(label: "Priority", value: "nice \(process.nice)")
                FactRow(label: "Kind", value: process.isTranslated ? "Intel (Rosetta)" : "Apple silicon")
                if let start = process.startTime {
                    FactRow(label: "Started", value: start.formatted(date: .abbreviated, time: .standard))
                }
                FactRow(label: "Parent", value: parentDescription(process))
                if process.responsiblePID != process.pid {
                    FactRow(label: "Responsible", value: describe(process.responsiblePID))
                }
            }

            if let path = process.executablePath {
                labelled("Executable", path)
            }
            if let directory = details.directory {
                labelled("Working directory", directory)
            }
            if let command = details.arguments?.commandLine {
                labelled("Command line", command)
            } else if details.loaded {
                Text("Command line and environment are only visible for your own processes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let variables = details.arguments?.environment, !variables.isEmpty {
                ForEach(variables) { variable in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(variable.name).font(.caption.weight(.semibold))
                        Text(variable.value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                unavailable("No environment available", "macOS only reveals the environment of your own processes.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Sockets only", isOn: $socketsOnly).toggleStyle(.checkbox).font(.subheadline)
            if let files = details.openFiles {
                let shown = socketsOnly ? files.filter { $0.socket != nil } : files
                ForEach(shown) { file in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: symbol(for: file))
                            .foregroundStyle(file.socket?.isListening == true ? .green : .secondary)
                            .frame(width: 14)
                        Text(file.detail).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    }
                }
                if shown.isEmpty {
                    Text("Nothing open.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                unavailable("Open files unavailable", "macOS only lists open files for your own processes.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ process: ProcessSample) -> some View {
        HStack {
            Button("End Task") { model.endTask([pid]) }
                .buttonStyle(.borderedProminent)
                .help("Ask \(process.name) to quit, so it can save its work first")
            Menu {
                if process.state == .stopped {
                    Button("Resume") { model.send(.continue, to: [pid]) }
                } else {
                    Button("Suspend") { model.send(.stop, to: [pid]) }
                }
                Button("Sample Process") { model.sampleProcess(pid) }
                Button("Reveal in Finder") { model.revealInFinder(pid) }
                Button("Search Online") { model.searchOnline(pid) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            // Kept apart from End Task, and confirmed, because it can't be undone.
            Button(role: .destructive) {
                confirmingForceQuit = true
            } label: {
                Label("Force Quit", systemImage: "xmark.octagon")
            }
            .foregroundStyle(.red)
            .help("Stop \(process.name) at once, without letting it save")
            .confirmationDialog("Force quit \(process.name)?", isPresented: $confirmingForceQuit) {
                Button("Force Quit", role: .destructive) { model.forceQuit([pid]) }
            } message: {
                Text("It stops immediately, and any unsaved work in it is lost.")
            }
        }
    }

    // MARK: Helpers

    private func loadDetails() async {
        details = Details()
        // Re-read open files every few seconds while this process is selected.
        while !Task.isCancelled {
            let pid = pid
            let loaded = await Task.detached(priority: .utility) {
                Details(
                    arguments: ProcessInspector.arguments(of: pid),
                    directory: ProcessInspector.currentDirectory(of: pid),
                    openFiles: ProcessInspector.openFiles(of: pid),
                    loaded: true
                )
            }.value
            details = loaded
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func parentDescription(_ process: ProcessSample) -> String {
        describe(process.parentPID)
    }

    private func describe(_ pid: Int32) -> String {
        guard let other = model.process(pid) else { return String(pid) }
        return "\(model.displayName(for: other)) (\(pid))"
    }

    private func symbol(for file: OpenFile) -> String {
        switch file.kind {
        case .socket: file.socket?.isListening == true ? "antenna.radiowaves.left.and.right" : "network"
        case .directory: "folder"
        case .pipe: "arrow.left.arrow.right"
        case .file, .other: "doc"
        }
    }
}
