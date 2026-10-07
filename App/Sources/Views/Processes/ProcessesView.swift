import OTMKit
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("processViewMode") private var mode: ProcessViewMode = .grouped
    @AppStorage("processSortKey") private var sortKey: ProcessSortKey = .cpu
    @AppStorage("processSortAscending") private var ascending = false
    @AppStorage("heatmap") private var heatmap = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("hiddenProcessColumns") private var hiddenColumns = HiddenProcessColumns.defaults
    @State private var search = ""
    @State private var selection: Set<Int32> = []
    /// Width the table needs for the columns that always stay, as it last measured.
    @State private var tableMinimum = ProcessColumn.defaultTableMinimum
    /// Columns that are on but hidden because the table is too narrow.
    @State private var hiddenToFit: Set<ProcessColumn> = []
    /// The window is too narrow for the table and the inspector side by side.
    @State private var isNarrow = false
    /// In a narrow window, the inspector covers the table.
    @State private var showsFullDetail = false

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot {
                // The table gets the full width until there's something to inspect.
                InspectorSplit(
                    listMinimum: tableMinimum,
                    wantsInspector: showInspector && !selection.isEmpty,
                    coversList: $showsFullDetail,
                    isNarrow: $isNarrow,
                    widthKey: "processInspectorWidth",
                    backTitle: "Processes"
                ) {
                    ProcessOutlineView(
                        // Covered by the inspector, the table is hidden and not updated.
                        configuration: isNarrow && showsFullDetail ? nil : configuration(for: snapshot),
                        selection: $selection,
                        sortKey: $sortKey,
                        ascending: $ascending,
                        model: model,
                        onShowInspector: openDetails,
                        onToggleColumn: { hiddenColumns.toggle($0) },
                        onMinimumWidthChange: { tableMinimum = $0 },
                        onHiddenToFitChange: { hiddenToFit = $0 }
                    )
                } detail: {
                    inspector
                }
                Divider()
                StatusBar(snapshot: snapshot)
                    .onAppear(perform: selectRequestedProcess)
            } else {
                ProgressView("Reading processes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: isNarrow) {
            // The split covers the table with an open inspector when the window
            // turns narrow. At launch it can decide that before `-openProcess`'s
            // selection reaches it, so apply the same rule to the selection as it is now.
            if isNarrow, showInspector, !selection.isEmpty { showsFullDetail = true }
        }
        // Matches names, PIDs, users and paths; a short prompt stays whole in the toolbar.
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .toolbar {
            // First, so it's the last to fold into the overflow menu.
            ToolbarItem {
                modeMenu
            }
            ToolbarItem {
                columnsMenu
            }
            ToolbarItem {
                Button {
                    model.endTask(Array(selection))
                } label: {
                    Label("End Task", systemImage: "xmark.octagon")
                }
                .disabled(selection.isEmpty)
                .help(selection.count > 1 ? "End Task: ask the \(selection.count) selected processes to quit (Delete)"
                    : "End Task: ask the selected process to quit (Delete)")
            }
            ToolbarItem {
                Button(action: toggleDetails) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(isNarrow && !showsFullDetail && selection.isEmpty)
                .help(detailsHelp)
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let pid = selection.first, selection.count == 1, model.process(pid) != nil {
            ProcessInspectorView(pid: pid)
        } else if let pid = selection.first, selection.count == 1 {
            ContentUnavailableView(
                "Process ended",
                systemImage: "info.circle",
                description: Text("PID \(String(pid)) is no longer running.")
            )
        } else {
            ContentUnavailableView(
                selection.count > 1 ? "\(selection.count) processes selected" : "No process selected",
                systemImage: "info.circle",
                description: Text("Select a single process to see its details.")
            )
        }
    }

    /// How the rows are arranged, named in the toolbar rather than three
    /// look-alike icons, with the choices ticked in its menu.
    private var modeMenu: some View {
        Menu {
            Picker("View", selection: $mode) {
                ForEach(ProcessViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(mode.title, systemImage: mode.symbol)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("View: group helpers under their app (Grouped), show which process started which (Tree), "
            + "or list every process on its own (Flat)")
    }

    /// Optional columns, also in the header's context menu. Hiding one makes
    /// room rather than squeezing the others' headings. A column that's on
    /// but hidden to fit the width stays ticked and says so.
    private var columnsMenu: some View {
        Menu {
            ForEach(ProcessColumn.allCases.filter { $0 != .name }, id: \.self) { column in
                Toggle(column.menuTitle(hiddenToFit: hiddenToFit.contains(column)), isOn: Binding(
                    get: { !hiddenColumns.contains(column) },
                    set: { if $0 == hiddenColumns.contains(column) { hiddenColumns.toggle(column) } }
                ))
            }
            if !hiddenToFit.isEmpty {
                Divider()
                Text(ProcessColumn.hiddenToFitNote)
            }
            Divider()
            Button("Default Columns") { hiddenColumns = .defaults }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .help(hiddenToFit.isEmpty ? "Columns: choose what the table shows"
            : "Columns: choose what the table shows. Some are hidden until there's room for them")
    }

    private var detailsHelp: String {
        if isNarrow {
            return showsFullDetail ? "Details: go back to the process list" : "Details: show everything about the selected process"
        }
        return showInspector ? "Details: hide the pane beside the table"
            : "Details: show a pane with the selected process's graphs, environment and open files"
    }

    /// Double-click, Get Info and requests from other pages: the pane in a
    /// wide window, the full-width details in a narrow one.
    private func openDetails() {
        showInspector = true
        if isNarrow { showsFullDetail = true }
    }

    private func toggleDetails() {
        if isNarrow {
            if showsFullDetail { showsFullDetail = false } else { openDetails() }
        } else {
            showInspector.toggle()
        }
    }

    /// Selects a process another page asked for ("Show process" on the
    /// Connections page), or once at launch the one given by
    /// `--args -openProcess <pid>`, for screenshots.
    private func selectRequestedProcess() {
        if let pid = model.requestedProcess {
            model.requestedProcess = nil
            guard model.process(pid) != nil else { return }
            search = ""
            selection = [pid]
            openDetails()
            return
        }
        guard selection.isEmpty, let pid = LaunchArgument.string("openProcess").flatMap(Int32.init),
              model.process(pid) != nil else { return }
        selection = [pid]
        openDetails()
    }

    private func configuration(for snapshot: SystemSnapshot) -> ProcessTableConfiguration {
        let nodes = ProcessTreeBuilder.build(
            snapshot.processes,
            mode: mode,
            appPIDs: Set(model.regularApps.keys),
            filter: search
        )
        return ProcessTableConfiguration(
            nodes: ProcessTreeBuilder.sort(nodes, by: sortKey, ascending: ascending),
            headerTotals: headerTotals(snapshot),
            hiddenColumns: hiddenColumns,
            cpuScale: model.cpuScale,
            heatmap: heatmap,
            fastTierName: model.topology.tiers.first?.name ?? "P-core"
        )
    }

    private func headerTotals(_ snapshot: SystemSnapshot) -> [ProcessColumn: String] {
        var totals: [ProcessColumn: String] = [
            .cpu: Format.percent(snapshot.cpu.usage),
            .memory: Format.percent(snapshot.memory.usedFraction),
        ]
        // Unreported figures (a VM's GPU load, power without sensors) get no total rather than a 0.
        if let busy = snapshot.gpus.first?.deviceUtilization { totals[.gpu] = Format.percent(busy) }
        if let watts = snapshot.power.systemWatts { totals[.power] = Format.watts(watts) }
        let disk = snapshot.disks.reduce(0) { $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond }
        totals[.disk] = Format.bytesPerSecond(disk)
        return totals
    }
}

extension ProcessViewMode {
    var title: String {
        switch self {
        case .grouped: "Grouped"
        case .tree: "Tree"
        case .flat: "Flat"
        }
    }

    var symbol: String {
        switch self {
        case .grouped: "square.stack.3d.up"
        case .tree: "list.bullet.indent"
        case .flat: "list.bullet"
        }
    }
}

private struct StatusBar: View {
    var snapshot: SystemSnapshot

    var body: some View {
        HStack(spacing: 16) {
            Text("\(snapshot.processes.count) processes")
            Text("CPU \(Format.percent(snapshot.cpu.usage))")
            Text("Memory \(Format.percent(snapshot.memory.usedFraction))")
            if let busy = snapshot.gpus.first?.deviceUtilization {
                Text("GPU \(Format.percent(busy))")
            }
            if let watts = snapshot.power.systemWatts {
                Text("Power \(Format.watts(watts))")
            }
            Spacer()
            if snapshot.processes.contains(where: \.isRestricted) {
                // Gives way first in a narrow window, on one line; the tooltip has it all.
                Text("System processes show CPU and memory only")
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help("System processes show CPU and memory only: macOS only reveals footprint, power, GPU and disk use "
                        + "for your own processes. A privileged helper will lift this.")
            }
            Text("Up \(Format.duration(snapshot.uptime))")
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
