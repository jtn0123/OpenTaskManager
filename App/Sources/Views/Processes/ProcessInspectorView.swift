import OTMKit
import SwiftUI

/// What the table's row for the inspected process counts besides it: in
/// Grouped, its app's helpers; in Tree, the processes under it. A collapsed
/// row shows the sum, so its figures differ from the inspector's.
struct ProcessRowGroup {
    var totals: ProcessTotals
    var mode: ProcessViewMode
    /// Expanded, the row shows the process's own figures, the others under it.
    var isExpanded: Bool
    /// Expands the row in the table.
    var show: () -> Void

    private var others: Int { max(totals.processCount - 1, 0) }

    /// "its 2 helpers", "the 3 processes under it".
    private var othersPhrase: String {
        switch mode {
        case .tree: others == 1 ? "the process under it" : "the \(others) processes under it"
        case .grouped, .flat: others == 1 ? "its helper" : "its \(others) helpers"
        }
    }

    /// The row as the table names it: Grouped's count badge is the group's
    /// size, while Tree's counts only the processes directly under it.
    private func row(_ name: String) -> String {
        mode == .tree ? name : "\(name) (\(totals.processCount))"
    }

    /// Where the table's figures for `name`'s row come from, with `cpu`
    /// formatted on the page's CPU scale.
    func summary(name: String, cpu: String) -> String {
        let figures = "\(Format.bytes(totals.memory)), \(cpu) CPU"
        return isExpanded
            ? "Together with \(othersPhrase), listed under it in the table: \(figures)."
            : "The table's \(row(name)) row includes \(othersPhrase): \(figures) in all."
    }

    var showTitle: String {
        switch mode {
        case .tree: "Expand Row"
        case .grouped, .flat: others == 1 ? "Show Helper" : "Show Helpers"
        }
    }
}

/// One process, by PID and start time: a PID macOS gives to a later process
/// never shows here as this one.
struct ProcessInspectorView: View {
    @Environment(AppModel.self) private var model
    let identity: ProcessIdentity
    /// Set when the selected row has processes nested under it.
    var group: ProcessRowGroup?
    /// Selects another process in the table: an ancestor, or the responsible one.
    var onSelect: (ProcessIdentity) -> Void

    @State private var details: Details?
    @State private var openFiles: OpenFiles?
    @State private var tab: Tab = .requestedAtLaunch
    @State private var socketsOnly = false
    @State private var confirmingForceQuit = false
    @State private var showsCommandLine = false
    @State private var showsEnvironment = false

    /// Read every few seconds while the Overview shows.
    struct Details: Equatable {
        var identity: ProcessIdentity
        var arguments: ProcessArguments?
        var directory: String?
    }

    /// Read every few seconds while Files & Ports shows.
    struct OpenFiles: Equatable {
        var identity: ProcessIdentity
        var files: [OpenFile]?
    }

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case threads = "Threads"
        case files = "Files & Ports"
        /// The row's process and those nested under it, as a whole
        /// (`ProcessGroupView`); offered only when there are some.
        case group = "Group"

        /// `-openProcessTab threads|files|group`, with `-openProcess`, for screenshots.
        static var requestedAtLaunch: Tab {
            switch LaunchArgument.string("openProcessTab") {
            case "threads": .threads
            case "files": .files
            case "group": .group
            default: .overview
            }
        }
    }

    private var pid: Int32 { identity.pid }

    /// The tab on screen: Group falls back to the Overview for a row with
    /// nothing nested under it, and comes back for the next one that has.
    private var shownTab: Tab {
        tab == .group && group == nil ? .overview : tab
    }

    var body: some View {
        if let process = model.process(identity) {
            VStack(alignment: .leading, spacing: 12) {
                header(process)
                if let group, shownTab != .group {
                    RowGroupNote(text: group.summary(name: model.displayName(for: process),
                                                     cpu: model.cpuScale.format(group.totals.cpuPercent)),
                                 showTitle: group.isExpanded ? nil : group.showTitle, show: group.show,
                                 count: group.totals.processCount, openGroup: { tab = .group })
                }
                Picker("", selection: Binding(get: { shownTab }, set: { tab = $0 })) {
                    ForEach(Tab.allCases.filter { $0 != .group || group != nil }, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Edge to edge, so the scroller runs down the pane's margin
                // rather than over the content's right edge (the Threads
                // tab's Priority column).
                ScrollView {
                    Group {
                        switch shownTab {
                        case .overview: overview(process)
                        case .threads: ProcessThreadsView(process: process)
                        case .files: files
                        case .group: ProcessGroupView(root: identity, mode: group?.mode ?? .grouped, onSelect: onSelect)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.horizontal, -12)
                if shownTab == .group, let group {
                    ProcessGroupActions(root: identity, mode: group.mode, canEnd: !process.isRestricted)
                } else {
                    actions(process)
                }
            }
            .padding(12)
            .task(id: shownTab == .overview ? identity : nil) { await loadDetails() }
            .task(id: shownTab == .files ? identity : nil) { await loadOpenFiles() }
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
                Text("PID \(String(process.pid)) · \(process.userName) · \(process.state.rawValue)")
                    .font(.callout).foregroundStyle(.secondaryText)
            }
        }
    }

    private func graphs(_ process: ProcessSample) -> some View {
        let history = model.processHistory[identity]?.values ?? []
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
            // Named for what it plots, the table's Memory figure for this process.
            GraphPanel(
                title: process.isRestricted ? "Resident memory" : "Memory footprint",
                trailing: Format.bytes(process.memory),
                series: [GraphSeries(values: history.map { Double($0.memory) }, color: Theme.memory)],
                height: 80,
                minimumCeiling: 1_048_576,
                axis: { Format.bytes(UInt64(max($0, 0))) },
                axisUnits: .binaryBytes,
                capacity: AppModel.processHistoryCapacity - 2
            )
            .help(process.isRestricted ? MemoryMeasure.restricted : MemoryMeasure.footprint)
            if !process.isRestricted {
                if measuresPower {
                    HStack(spacing: 12) {
                        GraphPanel(
                            title: "Power",
                            trailing: process.powerWatts.map(Format.watts) ?? "—",
                            // Unmeasured power is kept as 0 W, so draw nothing (the
                            // graph's "not recorded" shading) rather than a zero line.
                            series: [GraphSeries(values: process.powerWatts == nil ? [] : history.map(\.powerWatts), color: Theme.power)],
                            height: 60,
                            minimumCeiling: 0.5,
                            axis: Format.watts,
                            capacity: AppModel.processHistoryCapacity - 2
                        )
                        if process.gpuTime != nil { gpuGraph(process, history: history) }
                    }
                } else {
                    // Without power sensors (a VM) every reading would be "—",
                    // so one line says so instead of a graph with nothing in it.
                    NoticeStrip(title: "Power", symbol: "bolt.fill", color: Theme.power, text: "Not reported on this Mac",
                                help: Unavailable.energy, compact: true)
                    if process.gpuTime != nil { gpuGraph(process, history: history) }
                }
            }
        }
    }

    private func gpuGraph(_ process: ProcessSample, history: [ProcessPoint]) -> some View {
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

    private func overview(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            graphs(process)
            if process.isRestricted {
                Text("macOS shows other users' and system processes' CPU, memory and a few facts. "
                    + "The rest needs admin rights, and says so below.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
            activity(process)
            ProcessDiagnosticsSections(process: process)
            ProcessAncestryList(process: process, onSelect: onSelect)
            command(process)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activity(_ process: ProcessSample) -> some View {
        let restricted = process.isRestricted
        func own(_ value: @autoclosure () -> String) -> ProcessField<String> {
            restricted ? .denied : .value(value())
        }
        return VStack(alignment: .leading, spacing: 6) {
            InspectorHeading("Activity")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ProcessFieldRow("CPU time", Format.cpuTime(process.cpuTime),
                                help: "CPU time: how long its threads have run on a core since it started, all cores together")
                if measuresPower {
                    ProcessFieldRow("Power", restricted ? .denied : .value(process.powerWatts.map(Format.watts) ?? "—"))
                }
                ProcessFieldRow("Disk read", own("\(Format.bytesPerSecond(process.diskReadRate)) · \(Format.bytes(process.diskReadTotal)) total"))
                ProcessFieldRow("Disk written",
                                own("\(Format.bytesPerSecond(process.diskWriteRate)) · \(Format.bytes(process.diskWriteTotal)) total"))
                ProcessFieldRow("Wakeups", restricted ? .denied : .value(process.wakeupsPerSecond.map { Format.fixed($0, 0) + "/s" } ?? "—"),
                                help: "Wakeups: times a second its threads woke from waiting. Each costs energy, so fewer is better.")
                if let share = process.topTierShare {
                    ProcessFieldRow("On \(model.topology.tiers.first?.name ?? "fast") cores", Format.percent(share))
                }
                if let gpu = process.gpuTime {
                    ProcessFieldRow("GPU", "\(Format.percent(process.gpuFraction ?? 0, digits: 1)) · \(Format.cpuTime(gpu)) total")
                }
                ProcessFieldRow("Kind", process.isTranslated ? "Intel (Rosetta)" : "Apple silicon")
                if let start = process.startTime {
                    ProcessFieldRow("Started", start.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
    }

    /// Where it runs from and how it was started. Long values fold away;
    /// paths show their name over their folder.
    private func command(_ process: ProcessSample) -> some View {
        let details = details?.identity == identity ? details : nil
        return VStack(alignment: .leading, spacing: 8) {
            InspectorHeading("Command")
            if let path = process.executablePath {
                labelled("Executable") { CopyableText(value: path, splitsPath: true).font(.callout) }
            }
            if let directory = details?.directory {
                labelled("Working directory") { CopyableText(value: directory, splitsPath: true).font(.callout) }
            } else if details != nil, process.isRestricted {
                deniedRow("Working directory")
            }
            if let arguments = details?.arguments {
                DetailDisclosure("Command line", preview: arguments.commandLine, isExpanded: $showsCommandLine) {
                    CopyableText(value: arguments.commandLine).font(.callout)
                }
                environment(arguments.environment)
            } else if details != nil {
                // Read for your own processes only.
                deniedRow("Command line")
                deniedRow("Environment")
            }
        }
    }

    @ViewBuilder private func environment(_ variables: [EnvironmentVariable]) -> some View {
        if variables.isEmpty {
            HStack(spacing: 4) {
                Text("Environment").foregroundStyle(.secondaryText)
                Text("None shown")
            }
            .font(.callout)
            .help("macOS gave no environment variables for it. It keeps them back for some processes, Apple's own among them.")
        } else {
            DetailDisclosure("Environment", preview: "\(variables.count) variables", isExpanded: $showsEnvironment) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(variables) { variable in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(variable.name).font(.callout.weight(.semibold))
                            Text(variable.value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(4)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Sockets only", isOn: $socketsOnly).toggleStyle(.checkbox).font(.callout)
            if let state = openFiles, state.identity == identity {
                if let files = state.files {
                    let shown = socketsOnly ? files.filter { $0.socket != nil } : files
                    ForEach(shown) { file in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: symbol(for: file))
                                .foregroundStyle(file.socket?.isListening == true ? .green : .secondary)
                                .frame(width: 14)
                            Text(file.detail).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing open.").font(.explanation).foregroundStyle(.secondaryText)
                    }
                } else {
                    unavailable("Open files not readable without admin rights",
                                "macOS lists open files and sockets only for your own processes, or to an administrator (root).")
                }
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
                Button("Copy Path") { copy(process.executablePath ?? "") }
                    .disabled(process.executablePath == nil)
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

    /// Unknown counts as measured until the first samples say, like the Overview.
    private var measuresPower: Bool {
        model.measuresProcessEnergy != false
    }

    /// Arguments and working directory, every few seconds while the Overview
    /// shows; state changes only when they do.
    private func loadDetails() async {
        guard shownTab == .overview else { return }
        let identity = identity
        while !Task.isCancelled {
            let loaded = await Task.detached(priority: .utility) {
                Details(identity: identity, arguments: ProcessInspector.arguments(of: identity.pid),
                        directory: ProcessInspector.currentDirectory(of: identity.pid))
            }.value
            if !Task.isCancelled, loaded != details { details = loaded }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Open files and sockets, every few seconds while Files & Ports shows.
    private func loadOpenFiles() async {
        guard shownTab == .files else { return }
        let identity = identity
        while !Task.isCancelled {
            let loaded = await Task.detached(priority: .utility) {
                OpenFiles(identity: identity, files: ProcessInspector.openFiles(of: identity.pid))
            }.value
            if !Task.isCancelled, loaded != openFiles { openFiles = loaded }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func labelled<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondaryText)
            value()
        }
    }

    private func deniedRow(_ label: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondaryText)
            Text(ProcessAccess.denied).foregroundStyle(.secondaryText)
        }
        .font(.callout)
        .help(ProcessAccess.deniedHelp)
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(detail).font(.explanation).foregroundStyle(.secondaryText)
        }
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

/// Under the inspector's header when the selected row has processes nested
/// under it: the figures below are this process's alone, what the table's
/// row adds, and a button that expands the row to show them one by one,
/// and a link to the Group tab, which takes them together.
private struct RowGroupNote: View {
    /// `ProcessRowGroup.summary`.
    var text: String
    /// The button's title; nil once the row is expanded.
    var showTitle: String?
    var show: () -> Void
    /// The row's processes, this one included.
    var count: Int
    var openGroup: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondaryText)
                Text("This process only").fontWeight(.medium)
                Spacer(minLength: 4)
                if let showTitle {
                    Button(showTitle, action: show)
                        .controlSize(.small)
                        .help("Expand its row in the table, so each process shows its own figures")
                }
            }
            Text(text).font(.explanation).foregroundStyle(.secondaryText)
            Button(count == 2 ? "See both together" : "See all \(count) together", action: openGroup)
                .buttonStyle(.link)
                .font(.explanation)
                .help("Open the Group tab: their CPU over time, their figures added up, and each of them with why it's in the group")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}
