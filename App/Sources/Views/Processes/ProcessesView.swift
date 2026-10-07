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
    /// Width the table needs for its visible columns, as it last measured.
    @State private var tableMinimum = ProcessColumn.defaultTableMinimum
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
                        onMinimumWidthChange: { tableMinimum = $0 }
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
        .searchable(text: $search, placement: .toolbar, prompt: "Name, PID, user or path")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $mode) {
                    Label("Grouped", systemImage: "square.stack.3d.up").tag(ProcessViewMode.grouped)
                    Label("Tree", systemImage: "list.bullet.indent").tag(ProcessViewMode.tree)
                    Label("Flat", systemImage: "list.bullet").tag(ProcessViewMode.flat)
                }
                .pickerStyle(.segmented)
                .help("Group helpers under their app, show the parent/child tree, or list every process")
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
                .help("Quit the selected processes (Delete)")
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

    /// Optional columns, also in the header's context menu. Hiding one makes
    /// room rather than squeezing the others' headings.
    private var columnsMenu: some View {
        Menu {
            ForEach(ProcessColumn.allCases.filter { $0 != .name }, id: \.self) { column in
                Toggle(column.title, isOn: Binding(
                    get: { !hiddenColumns.contains(column) },
                    set: { if $0 == hiddenColumns.contains(column) { hiddenColumns.toggle(column) } }
                ))
            }
            Divider()
            Button("Default Columns") { hiddenColumns = .defaults }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .help("Choose the table's columns")
    }

    private var detailsHelp: String {
        if isNarrow {
            return showsFullDetail ? "Back to the process list" : "Show the selected process's details"
        }
        return showInspector ? "Hide the details pane" : "Show details when a process is selected"
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
