import OTMKit
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("processViewMode") private var mode: ProcessViewMode = .grouped
    @AppStorage("processSortKey") private var sortKey: ProcessSortKey = .cpu
    @AppStorage("processSortAscending") private var ascending = false
    @AppStorage("heatmap") private var heatmap = true
    @AppStorage("showInspector") private var showInspector = true
    @State private var search = ""
    @State private var selection: Set<Int32> = []

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot {
                ProcessOutlineView(
                    configuration: configuration(for: snapshot),
                    selection: $selection,
                    sortKey: $sortKey,
                    ascending: $ascending,
                    model: model,
                    onShowInspector: { showInspector = true }
                )
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
                Button {
                    model.endTask(Array(selection))
                } label: {
                    Label("End Task", systemImage: "xmark.octagon")
                }
                .disabled(selection.isEmpty)
                .help("Quit the selected processes (Delete)")
            }
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide the details pane" : "Show details when a process is selected")
            }
        }
        // The table gets the full width until there's something to inspect.
        .inspector(isPresented: Binding(get: { showInspector && !selection.isEmpty }, set: { showInspector = $0 })) {
            Group {
                if let pid = selection.first, selection.count == 1, model.process(pid) != nil {
                    ProcessInspectorView(pid: pid)
                } else {
                    ContentUnavailableView(
                        selection.count > 1 ? "\(selection.count) processes selected" : "No process selected",
                        systemImage: "info.circle",
                        description: Text("Select a single process to see its details.")
                    )
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
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
            showInspector = true
            return
        }
        guard selection.isEmpty, let pid = LaunchArgument.string("openProcess").flatMap(Int32.init),
              model.process(pid) != nil else { return }
        selection = [pid]
        showInspector = true
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
        if let gpu = snapshot.gpus.first { totals[.gpu] = Format.percent(gpu.deviceUtilization) }
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
            if let gpu = snapshot.gpus.first {
                Text("GPU \(Format.percent(gpu.deviceUtilization))")
            }
            if let watts = snapshot.power.systemWatts {
                Text("Power \(Format.watts(watts))")
            }
            Spacer()
            if snapshot.processes.contains(where: \.isRestricted) {
                Text("System processes show CPU and memory only")
                    .help("macOS only reveals footprint, power, GPU and disk use for your own processes. A privileged helper will lift this.")
            }
            Text("Up \(Format.duration(snapshot.uptime))")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
