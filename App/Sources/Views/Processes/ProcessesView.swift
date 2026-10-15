import OTMKit
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @Setting(Settings.processViewMode) private var mode: ProcessViewMode
    @Setting(Settings.processSortKey) private var sortKey: ProcessSortKey
    @Setting(Settings.processSortAscending) private var ascending: Bool
    @Setting(Settings.heatmap) private var heatmap: Bool
    @Setting(Settings.showInspector) private var showInspector: Bool
    @Setting(Settings.hiddenProcessColumns) private var hiddenColumns: HiddenProcessColumns
    @Setting(Settings.processNameWidth) private var nameWidth: Double
    @State private var search = ""
    @State private var showsFindOwner = false
    @State private var didOpenFindOwner = false
    @State private var ownerInitialQuery = ""
    /// By PID and start time, so a selected process that ends never hands
    /// its inspector, or End Task, to a later process given its PID.
    @State private var selection: Set<ProcessIdentity> = []
    /// Width the table needs for the columns that always stay, as it last measured.
    @State private var tableMinimum = ProcessColumn.defaultTableMinimum
    /// Columns that are on but hidden because the table is too narrow.
    @State private var hiddenToFit: Set<ProcessColumn> = []
    /// The window is too narrow for the table and the inspector side by side.
    @State private var isNarrow = false
    /// In a narrow window, the inspector covers the table.
    @State private var showsFullDetail = false
    /// Process rows the user expanded, so the inspector knows whether the
    /// selected row shows its own figures or its group's.
    @State private var expandedRows: Set<Int64> = []
    @State private var tableLink = ProcessTableLink()
    /// What Force Quit would end, and their names, fixed as its confirmation opens.
    @State private var forceQuitTargets: [ProcessIdentity] = []
    @State private var forceQuitNames: [String] = []
    @State private var confirmsForceQuit = false
    /// A narrow window, where End Task drops its word.
    @Environment(\.compactToolbar) private var compactToolbar

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot {
                // Covered by the inspector, the table is hidden and not updated.
                let table = isNarrow && showsFullDetail ? nil : configuration(for: snapshot)
                // The table gets the full width until there's something to inspect.
                InspectorSplit(
                    listMinimum: tableMinimum,
                    wantsInspector: showInspector && !selection.isEmpty,
                    coversList: $showsFullDetail,
                    isNarrow: $isNarrow,
                    widthKey: Settings.processInspectorWidth,
                    backTitle: "Processes"
                ) {
                    ProcessOutlineView(
                        configuration: table,
                        selection: $selection,
                        sortKey: $sortKey,
                        ascending: $ascending,
                        model: model,
                        onShowInspector: openDetails,
                        onForceQuit: requestForceQuit,
                        onToggleColumn: { hiddenColumns.toggle($0, unreported: unreportedColumns) },
                        onNameWidthChange: { nameWidth = Double($0) },
                        onMinimumWidthChange: { tableMinimum = $0 },
                        onHiddenToFitChange: { hiddenToFit = $0 },
                        link: tableLink,
                        onExpandedChange: { expandedRows = $0 }
                    )
                } detail: {
                    inspector(group: selectedRowGroup(in: table?.nodes, snapshot: snapshot))
                }
                Divider()
                StatusBar(snapshot: snapshot)
                    .onAppear(perform: selectRequestedProcess)
            } else {
                ProgressView("Reading processes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .samplingDemand(.restrictedProcesses)
        .sheet(isPresented: $showsFindOwner, onDismiss: { ownerInitialQuery = "" }, content: {
            FindOwnerSheet(initialQuery: ownerInitialQuery) { identity in
                guard model.process(identity) != nil else { return false }
                select(identity)
                if isNarrow { showsFullDetail = false }
                showsFindOwner = false
                return true
            }
        })
        .onAppear {
            if !didOpenFindOwner, let query = LaunchArgument.string("openFindOwner") {
                ownerInitialQuery = query
                didOpenFindOwner = true
                showsFindOwner = true
            }
        }
        .onChange(of: isNarrow) {
            // The split covers the table with an open inspector when the window
            // turns narrow. At launch it can decide that before `-openProcess`'s
            // selection reaches it, so apply the same rule to the selection as it is now.
            if isNarrow, showInspector, !selection.isEmpty { showsFullDetail = true }
        }
        .confirmationDialog(ForceQuitPrompt.title(names: forceQuitNames), isPresented: $confirmsForceQuit,
                            titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) { model.forceQuit(model.livePIDs(Set(forceQuitTargets))) }
        } message: {
            Text(ForceQuitPrompt.message(names: forceQuitNames))
        }
        // Matches names, PIDs, users and paths; a short prompt stays whole in the toolbar.
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .toolbar {
            // First, so it's the last to fold into the overflow menu.
            ToolbarItem {
                modeMenu
            }
            // Named where there's room. Columns is a submenu of the View
            // menu, so End Task and the search field both fit beside it.
            ToolbarItem {
                if compactToolbar {
                    endTaskMenu.labelStyle(.iconOnly)
                } else {
                    endTaskMenu.labelStyle(.titleAndIcon)
                }
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

    /// End Task, named, with Force Quit in its menu: the quit that lets a
    /// process save its work is the button, and the one that loses unsaved
    /// work is a step away and confirmed. Greyed until a row is selected.
    private var endTaskMenu: some View {
        Menu {
            Button("Force Quit…", action: requestForceQuit)
        } label: {
            Label("End Task", systemImage: "xmark.octagon")
        } primaryAction: {
            model.endTask(model.livePIDs(selection))
        }
        .fixedSize()
        .disabled(selection.isEmpty)
        .help(endTaskHelp)
    }

    private var endTaskHelp: String {
        let forceQuit = "Its menu has Force Quit, which stops at once, losing unsaved work (Option-Delete)"
        return switch selection.count {
        case 0: "End Task: select a process to end. It asks the process to quit, so it can save its work first (Delete). "
            + forceQuit
        case 1: "End Task: ask the selected process to quit, so it can save its work first (Delete). " + forceQuit
        default: "End Task: ask the \(selection.count) selected processes to quit, so they can save their work first "
            + "(Delete). " + forceQuit
        }
    }

    /// Toolbar's Force Quit or Option-Delete: asks first, naming what it ends.
    private func requestForceQuit() {
        let targets = selection.compactMap { identity in model.process(identity).map { (identity, $0) } }
            .sorted { $0.0.pid < $1.0.pid }
        guard !targets.isEmpty else { return }
        forceQuitTargets = targets.map(\.0)
        forceQuitNames = targets.map { model.displayName(for: $0.1) }
        confirmsForceQuit = true
    }

    @ViewBuilder private func inspector(group: ProcessRowGroup?) -> some View {
        if let selected = selection.first, selection.count == 1, model.process(selected) != nil {
            ProcessInspectorView(identity: selected, group: group, onSelect: select)
        } else if let selected = selection.first, selection.count == 1 {
            ContentUnavailableView(
                "Process ended",
                systemImage: "info.circle",
                description: Text("PID \(String(selected.pid)) is no longer running.")
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
    /// look-alike icons, with the choices ticked in its menu, and Columns as
    /// a submenu (also the table header's context menu): a toolbar menu of
    /// its own left no room for the search field beside a named End Task.
    private var modeMenu: some View {
        Menu {
            Picker("View", selection: $mode) {
                ForEach(ProcessViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Find Owner…") { showsFindOwner = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Menu {
                columnItems
            } label: {
                Label(hiddenToFit.isEmpty ? "Columns" : "Columns (some hidden to fit)", systemImage: "tablecells")
            }
        } label: {
            Label(mode.title, systemImage: mode.symbol)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("View: group helpers under their app (Grouped; sorted by name, PID or user, apps, background "
            + "and system processes are listed apart), show which process started which (Tree), or list every "
            + "process on its own (Flat); and choose the columns")
    }

    /// Optional columns, also in the header's context menu. Hiding one makes
    /// room rather than squeezing the others' headings. A column that's on
    /// but hidden to fit the width stays ticked and says so; one this Mac
    /// doesn't report says that, and shows its dashes once ticked.
    @ViewBuilder private var columnItems: some View {
        let unreported = unreportedColumns
        ForEach(ProcessColumn.allCases.filter { $0 != .name }, id: \.self) { column in
            let title = column.menuTitle(hiddenToFit: hiddenToFit.contains(column), unreported: unreported.contains(column))
            Toggle(title, isOn: Binding(
                get: { hiddenColumns.isOn(column, unreported: unreported) },
                set: { isOn in
                    if isOn != hiddenColumns.isOn(column, unreported: unreported) { hiddenColumns.toggle(column, unreported: unreported) }
                }
            ))
        }
        if !hiddenToFit.isEmpty {
            Divider()
            Text(ProcessColumn.hiddenToFitNote)
        }
        Divider()
        Button("Default Columns") {
            hiddenColumns = .defaults
            nameWidth = Settings.processNameWidth.defaultValue
        }
    }

    /// Columns with nothing to show on this Mac, such as Power in a VM.
    /// Changes at most a few times per launch, so the table refits only then.
    private var unreportedColumns: Set<ProcessColumn> {
        ProcessColumn.unreported(measuresEnergy: model.measuresProcessEnergy, reportsGPU: model.reportsProcessGPU,
                                 reportsNeuralMemory: model.reportsProcessNeuralMemory)
    }

    /// What the selected row counts besides its process, when it has rows
    /// nested under it: the inspector shows the process alone and says so.
    /// Found in the table's rows; while the inspector covers the table, they
    /// are built here instead, unsorted, as the table would have them.
    private func selectedRowGroup(in nodes: [ProcessNode]?, snapshot: SystemSnapshot) -> ProcessRowGroup? {
        guard showInspector, selection.count == 1, let selected = selection.first, mode != .flat else { return nil }
        let pid = selected.pid
        let nodes = nodes ?? ProcessTreeBuilder.build(snapshot.processes, mode: mode, appPIDs: Set(model.regularApps.keys), filter: search)
        guard let node = ProcessTreeBuilder.node(for: pid, in: nodes), node.process?.identity == selected,
              !node.children.isEmpty else { return nil }
        return ProcessRowGroup(
            totals: node.totals,
            mode: mode,
            isExpanded: expandedRows.contains(node.id),
            show: { showNested(pid) }
        )
    }

    /// The inspector's Show Helpers: the row expanded, in view, beside the
    /// inspector or, in a narrow window, back in place of it.
    private func showNested(_ pid: Int32) {
        if isNarrow { showsFullDetail = false }
        tableLink.showNested(pid)
    }

    private var detailsHelp: String {
        if isNarrow {
            return showsFullDetail ? "Details: go back to the process list" : "Details: show everything about the selected process"
        }
        return showInspector ? "Details: hide the pane beside the table"
            : "Details: show a pane with the selected process's graphs, threads, ancestry and open files"
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
            guard let process = model.process(pid) else { return }
            search = ""
            selection = [process.identity]
            tableLink.reveal(process.identity)
            openDetails()
            return
        }
        guard selection.isEmpty, let pid = LaunchArgument.string("openProcess").flatMap(Int32.init),
              let process = model.process(pid) else { return }
        selection = [process.identity]
        tableLink.reveal(process.identity)
        openDetails()
    }

    /// The inspector's ancestry and responsible process: selects that one and
    /// opens and scrolls the table to its row, clearing a search it doesn't match.
    private func select(_ process: ProcessIdentity) {
        guard let sample = model.process(process) else { return }
        if !search.isEmpty, ProcessTreeBuilder.build([sample], mode: .flat, appPIDs: [], filter: search).isEmpty {
            search = ""
        }
        selection = [process]
        tableLink.reveal(process)
    }

    private func configuration(for snapshot: SystemSnapshot) -> ProcessTableConfiguration {
        let nodes = ProcessTreeBuilder.build(
            snapshot.processes,
            mode: mode,
            appPIDs: Set(model.regularApps.keys),
            filter: search
        )
        // Rows that read the same keep their order, rather than trading places
        // every tick over differences the CPU column doesn't show. Grouped,
        // sorted by a figure, ranks every group together.
        return ProcessTableConfiguration(
            nodes: ProcessTreeBuilder.arrange(nodes, by: sortKey, ascending: ascending, cpuStep: model.cpuScale.shownStep),
            headerTotals: headerTotals(snapshot),
            hiddenColumns: hiddenColumns,
            unreportedColumns: unreportedColumns,
            cpuScale: model.cpuScale,
            heatmap: heatmap,
            fastTierName: model.topology.tiers.first?.name ?? "P-core",
            nameWidth: CGFloat(nameWidth)
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
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
