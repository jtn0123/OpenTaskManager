import AppKit
import OTMKit
import SwiftUI

/// Columns of the process table. The raw value doubles as the column
/// identifier and, where sortable, the `ProcessSortKey`.
enum ProcessColumn: String, CaseIterable {
    case name, pid, cpu, memory, power, gpu, disk, threads, topTier, wakeups, user, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .pid: "PID"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .threads: "Threads"
        case .topTier: "Fast cores"
        case .wakeups: "Wakeups/s"
        case .user: "User"
        case .kind: "Kind"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 280
        case .user: 110
        case .pid, .threads, .kind: 64
        default: 80
        }
    }

    var hiddenByDefault: Bool {
        self == .wakeups || self == .kind || self == .topTier
    }

    var sortKey: ProcessSortKey? {
        switch self {
        case .kind: nil
        default: ProcessSortKey(rawValue: rawValue)
        }
    }

    var isNumeric: Bool {
        self != .name && self != .user && self != .kind
    }

    /// Colour of the meter bar behind busy values, matching the Performance page.
    @MainActor var meterColor: NSColor? {
        switch self {
        case .cpu: Self.colors.cpu
        case .memory: Self.colors.memory
        case .power: Self.colors.power
        case .gpu: Self.colors.gpu
        case .disk: Self.colors.disk
        case .wakeups: Self.colors.wakeups
        default: nil
        }
    }

    /// The meters sit behind the numbers, so they keep the pastel fill shade.
    @MainActor private static let colors = (
        cpu: NSColor(Theme.cpu).fillShade, memory: NSColor(Theme.memory).fillShade, power: NSColor(Theme.power).fillShade,
        gpu: NSColor(Theme.gpu).fillShade, disk: NSColor(Theme.disk).fillShade, wakeups: NSColor(Theme.network).fillShade
    )
}

/// Everything the table needs from SwiftUI on each refresh.
struct ProcessTableConfiguration {
    var nodes: [ProcessNode]
    /// Whole-system figures shown in the column headers, Windows-style.
    var headerTotals: [ProcessColumn: String]
    var cpuScale: CPUScale
    var heatmap: Bool
    var fastTierName: String
}

struct ProcessOutlineView: NSViewRepresentable {
    var configuration: ProcessTableConfiguration
    @Binding var selection: Set<Int32>
    @Binding var sortKey: ProcessSortKey
    @Binding var ascending: Bool
    var model: AppModel
    var onShowInspector: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProcessOutline()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.rowHeight = 22
        outline.style = .fullWidth
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = true

        for column in ProcessColumn.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 140 : 44
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            if let key = column.sortKey {
                // Numbers default to descending: biggest consumers first.
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: !column.isNumeric)
            }
            tableColumn.isHidden = column.hiddenByDefault
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        outline.autosaveName = "ProcessOutline"
        outline.autosaveTableColumns = true

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onDelete = { [weak coordinator] in coordinator?.endSelected() }
        let columnMenu = NSMenu()
        columnMenu.delegate = coordinator
        outline.headerView?.menu = columnMenu
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(configuration)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessOutlineView
        weak var outline: NSOutlineView?

        private var roots: [Item] = []
        private var items: [Int64: Item] = [:]
        private var configuration: ProcessTableConfiguration?
        private var collapsedSections: Set<Int64> = []
        private var expanded: Set<Int64> = []
        private var isRestoring = false
        /// The selection as last agreed between the table and SwiftUI. If
        /// SwiftUI's binding differs, something outside the table changed it.
        private var syncedSelection: Set<Int32> = []
        /// Each row's children in display order; top-level rows sit under
        /// `rootKey`. Compared between refreshes to update rows in place.
        private var layout: [Int64: [Int64]] = [:]
        private static let rootKey = Int64.min
        /// Largest value in each relative-scaled column this refresh.
        private var peaks = Peaks()

        struct Peaks {
            var memory: Double = 0
            var power: Double = 0
            var disk: Double = 0
            var wakeups: Double = 0
        }

        init(parent: ProcessOutlineView) {
            self.parent = parent
        }

        /// Outline items must keep their identity between refreshes so the
        /// outline view preserves expansion; we update them in place.
        final class Item {
            let id: Int64
            var node: ProcessNode
            var children: [Item] = []

            init(node: ProcessNode) {
                id = node.id
                self.node = node
            }

            var pid: Int32? { node.process?.pid }
        }

        func apply(_ configuration: ProcessTableConfiguration) {
            guard let outline else { return }
            // Reloading mid-click would swallow the click; the next tick catches up.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            self.configuration = configuration
            syncSortDescriptor(outline)
            for tableColumn in outline.tableColumns {
                guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                let base = column == .topTier ? "\(configuration.fastTierName) %" : column.title
                let title = configuration.headerTotals[column].map { "\(base)  \($0)" } ?? base
                if tableColumn.title != title { tableColumn.title = title }
            }

            var live: [Int64: Item] = [:]
            func materialize(_ node: ProcessNode) -> Item {
                let item = items[node.id] ?? Item(node: node)
                item.node = node
                item.children = node.children.map(materialize)
                live[node.id] = item
                return item
            }
            roots = configuration.nodes.map(materialize)
            items = live

            var peaks = Peaks()
            for item in live.values where item.node.process != nil {
                let totals = item.node.totals
                peaks.memory = max(peaks.memory, Double(totals.memory))
                peaks.power = max(peaks.power, totals.powerWatts)
                peaks.disk = max(peaks.disk, totals.diskRate)
                peaks.wakeups = max(peaks.wakeups, item.node.process?.wakeupsPerSecond ?? 0)
            }
            self.peaks = peaks

            var newLayout: [Int64: [Int64]] = [Self.rootKey: roots.map(\.id)]
            newLayout.reserveCapacity(live.count + 1)
            for item in live.values { newLayout[item.id] = item.children.map(\.id) }
            let oldLayout = layout
            layout = newLayout

            let tableSelection = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.pid })
            isRestoring = true
            // Rebuilding every row view costs far more than moving a few rows
            // and restyling the ones on screen, so reload only as a fallback.
            if newLayout != oldLayout, !applyIncrementally(from: oldLayout, to: newLayout, in: outline) {
                outline.reloadData()
            }
            restoreExpansion(roots, in: outline)
            refreshVisibleCells(in: outline)
            restoreSelection(in: outline, keeping: tableSelection)
            isRestoring = false
        }

        /// Row operations that turn the outline's current rows into the new layout.
        private struct UpdatePlan {
            var changes: [(parent: Item?, changes: OrderedDiff.Changes)] = []
            /// Parents whose rows aren't on screen; their children are re-read instead.
            var hidden: [Item] = []
        }

        /// Moves, inserts and removes rows to match the new layout. Returns
        /// false, having changed nothing, when a reload would be simpler.
        private func applyIncrementally(from old: [Int64: [Int64]], to new: [Int64: [Int64]], in outline: NSOutlineView) -> Bool {
            guard !old.isEmpty else { return false }
            let plan = plan(from: old, to: new, in: outline)
            guard plan.changes.reduce(0, { $0 + $1.changes.count }) <= 300,
                  !hasUnsafeReparenting(from: old, to: new, hidden: Set(plan.hidden.map(\.id))) else { return false }
            perform(plan, in: outline)
            return true
        }

        private func plan(from old: [Int64: [Int64]], to new: [Int64: [Int64]], in outline: NSOutlineView) -> UpdatePlan {
            var plan = UpdatePlan()
            for (parentID, children) in new {
                guard let previous = old[parentID], previous != children else { continue }
                if parentID == Self.rootKey {
                    plan.changes.append((nil, OrderedDiff.changes(from: previous, to: children)))
                } else if let parent = items[parentID] {
                    if outline.isItemExpanded(parent), outline.row(forItem: parent) >= 0 {
                        plan.changes.append((parent, OrderedDiff.changes(from: previous, to: children)))
                    } else {
                        plan.hidden.append(parent)
                    }
                }
            }
            return plan
        }

        /// A row that changed parent is a removal under one and an insert under
        /// the other. That's only safe when both parents are on screen; a hidden
        /// parent may still hold the row in its cache.
        private func hasUnsafeReparenting(from old: [Int64: [Int64]], to new: [Int64: [Int64]], hidden: Set<Int64>) -> Bool {
            var oldParent: [Int64: Int64] = [:]
            for (parent, children) in old {
                for child in children { oldParent[child] = parent }
            }
            for (parent, children) in new {
                for child in children {
                    guard let previous = oldParent[child], previous != parent else { continue }
                    if hidden.contains(previous) || hidden.contains(parent) || old[parent] == nil { return true }
                }
            }
            return false
        }

        private func perform(_ plan: UpdatePlan, in outline: NSOutlineView) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            outline.beginUpdates()
            // Every removal first, so a row changing parent never exists twice.
            for (parent, changes) in plan.changes where !changes.removals.isEmpty {
                outline.removeItems(at: IndexSet(changes.removals), inParent: parent, withAnimation: [])
            }
            for (parent, changes) in plan.changes {
                for step in changes.steps {
                    switch step {
                    case let .move(from, to):
                        outline.moveItem(at: from, inParent: parent, to: to, inParent: parent)
                    case let .insert(at):
                        outline.insertItems(at: IndexSet(integer: at), inParent: parent, withAnimation: [])
                    }
                }
            }
            outline.endUpdates()
            NSAnimationContext.endGrouping()
            for parent in plan.hidden { outline.reloadItem(parent, reloadChildren: true) }
            // Section headers show a count, and a row that gained or lost its
            // last child needs its disclosure triangle redrawn.
            for case let (parent?, _) in plan.changes {
                outline.reloadItem(parent, reloadChildren: false)
            }
        }

        private func refreshVisibleCells(in outline: NSOutlineView) {
            let rows = outline.rows(in: outline.visibleRect)
            for row in rows.lowerBound..<rows.upperBound {
                guard let item = outline.item(atRow: row) as? Item else { continue }
                if let section = item.node.section {
                    let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                    let title = "\(section.title) (\(item.children.count))"
                    if let label = cell?.textField, label.stringValue != title { label.stringValue = title }
                    continue
                }
                for (index, tableColumn) in outline.tableColumns.enumerated() where !tableColumn.isHidden {
                    guard let view = outline.view(atColumn: index, row: row, makeIfNecessary: false) else { continue }
                    configure(view, column: tableColumn, item: item, in: outline)
                }
            }
        }

        private func restoreExpansion(_ level: [Item], in outline: NSOutlineView) {
            for item in level where !item.children.isEmpty {
                let isSection = item.node.section != nil
                let shouldExpand = isSection ? !collapsedSections.contains(item.id) : expanded.contains(item.id)
                if shouldExpand {
                    outline.expandItem(item)
                    restoreExpansion(item.children, in: outline)
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                }
            }
        }

        private func restoreSelection(in outline: NSOutlineView, keeping tableSelection: Set<Int32>) {
            let wanted = parent.selection != syncedSelection ? parent.selection : tableSelection
            syncedSelection = wanted
            let rows = IndexSet(wanted.compactMap { pid -> Int? in
                guard let item = items[Int64(pid)] else { return nil }
                let row = outline.row(forItem: item)
                return row >= 0 ? row : nil
            })
            if rows != outline.selectedRowIndexes {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        private func syncSortDescriptor(_ outline: NSOutlineView) {
            let wanted = NSSortDescriptor(key: parent.sortKey.rawValue, ascending: parent.ascending)
            if outline.sortDescriptors.first != wanted {
                isRestoring = true
                outline.sortDescriptors = [wanted]
                isRestoring = false
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Item)?.children.isEmpty ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isRestoring, let descriptor = outlineView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(ProcessSortKey.init) else { return }
            parent.sortKey = key
            parent.ascending = descriptor.ascending
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Item)?.node.section != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Item)?.node.section == nil
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            track(notification, expanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            track(notification, expanded: false)
        }

        private func track(_ notification: Notification, expanded isExpanded: Bool) {
            guard !isRestoring, let item = notification.userInfo?["NSObject"] as? Item else { return }
            outline?.reloadItem(item, reloadChildren: false)
            if item.node.section != nil {
                if isExpanded { collapsedSections.remove(item.id) } else { collapsedSections.insert(item.id) }
            } else {
                if isExpanded { expanded.insert(item.id) } else { expanded.remove(item.id) }
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isRestoring, let outline else { return }
            let pids = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.pid })
            syncedSelection = pids
            parent.selection = pids

        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }

            if let section = item.node.section {
                let cell = reuse(outlineView, id: "section") { SectionCell() }
                cell.textField?.stringValue = "\(section.title) (\(item.children.count))"
                return cell
            }

            guard let tableColumn, let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue),
                  item.node.process != nil else { return nil }

            let cell: NSView = if column == .name {
                reuse(outlineView, id: "name") { NameCell() }
            } else {
                reuse(outlineView, id: column.isNumeric ? "number" : "text") {
                    ValueCell(alignment: column.isNumeric ? .right : .left)
                }
            }
            configure(cell, column: tableColumn, item: item, in: outlineView)
            return cell
        }

        private func configure(_ cell: NSView, column tableColumn: NSTableColumn, item: Item, in outline: NSOutlineView) {
            guard let configuration, let process = item.node.process,
                  let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            if let cell = cell as? NameCell {
                cell.configure(process: process, app: parent.model.regularApps[process.pid],
                               childCount: item.children.count, isExpanded: outline.isItemExpanded(item))
            } else if let cell = cell as? ValueCell {
                let (text, meter) = value(for: column, item: item, configuration: configuration)
                if cell.textField?.stringValue != text { cell.textField?.stringValue = text }
                cell.setMeter(configuration.heatmap ? meter : 0, color: column.meterColor)
            }
        }

        private func value(for column: ProcessColumn, item: Item, configuration: ProcessTableConfiguration) -> (String, Double) {
            guard let process = item.node.process else { return ("", 0) }
            // Collapsed groups show their totals, like Windows Task Manager.
            let grouped = !item.children.isEmpty && !(outline?.isItemExpanded(item) ?? false)
            let totals = grouped ? item.node.totals : ProcessTotals(process)
            switch column {
            case .name: return (process.name, 0)
            case .pid: return (String(process.pid), 0)
            case .cpu:
                // Percentages fill to their own value: 12% is an eighth of a bar.
                let shown = configuration.cpuScale.value(totals.cpuPercent)
                return (configuration.cpuScale.format(totals.cpuPercent), min(shown / 100, 1))
            case .memory:
                return (Format.bytes(totals.memory), Double(totals.memory) / max(peaks.memory, 1_073_741_824))
            case .power:
                // A group with no readings at all is unknown, not 0 W.
                guard totals.isPowerMeasured else { return ("—", 0) }
                return (Format.watts(totals.powerWatts), totals.powerWatts / max(peaks.power, 2))
            case .gpu:
                guard process.gpuFraction != nil || (grouped && totals.gpuFraction > 0) else { return ("—", 0) }
                return (Format.percent(totals.gpuFraction, digits: 1), min(totals.gpuFraction, 1))
            case .disk:
                guard !process.isRestricted || grouped else { return ("—", 0) }
                return (Format.bytesPerSecond(totals.diskRate), totals.diskRate / max(peaks.disk, 10_000_000))
            case .threads:
                return (totals.threads > 0 ? String(totals.threads) : "—", 0)
            case .topTier:
                return (process.topTierShare.map { Format.percent($0) } ?? "—", 0)
            case .wakeups:
                return (process.wakeupsPerSecond.map { Format.fixed($0, 0) } ?? "—", (process.wakeupsPerSecond ?? 0) / max(peaks.wakeups, 200))
            case .user:
                return (process.userName, 0)
            case .kind:
                return (process.isTranslated ? "Intel" : "Apple", 0)
            }
        }

        private func reuse<T: NSView>(_ outline: NSOutlineView, id: String, make: () -> T) -> T {
            if let view = outline.makeView(withIdentifier: .init(id), owner: nil) as? T { return view }
            let view = make()
            view.identifier = .init(id)
            return view
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? Item else { return }
            if item.pid != nil {
                parent.onShowInspector()
            } else {
                if sender.isItemExpanded(item) {
                    sender.collapseItem(item)
                } else {
                    sender.expandItem(item)
                }
            }
        }

        func endSelected() {
            let pids = Array(parent.selection)
            guard !pids.isEmpty else { return }
            parent.model.endTask(pids)
        }

        /// The rows a context menu acts on: the selection if the click landed
        /// inside it, otherwise just the clicked row.
        private func targetPIDs() -> [Int32] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
                return [(outline.item(atRow: clicked) as? Item)?.pid].compactMap { $0 }
            }
            return Array(parent.selection)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if let outline, menu === outline.headerView?.menu {
                buildColumnMenu(menu, outline: outline)
                return
            }
            let pids = targetPIDs()
            guard !pids.isEmpty else { return }
            let model = parent.model
            let single = pids.count == 1 ? model.process(pids[0]) : nil

            menu.addItem(ActionItem("End Task") { model.endTask(pids) })
            menu.addItem(ActionItem("Force Quit") { [weak self] in
                self?.confirm("Force quit \(pids.count == 1 ? (single?.name ?? "this process") : "\(pids.count) processes")?",
                              detail: "Unsaved data will be lost.") { model.forceQuit(pids) }
            })
            menu.addItem(ActionItem("End Process Tree") { [weak self] in
                self?.confirm("End the selected process tree?", detail: "Every process it started will be asked to quit.") {
                    model.endProcessTree(pids, force: false)
                }
            })
            menu.addItem(.separator())
            if single?.state == .stopped {
                menu.addItem(ActionItem("Resume") { model.send(.continue, to: pids) })
            } else {
                menu.addItem(ActionItem("Suspend") { model.send(.stop, to: pids) })
            }

            let signals = NSMenu()
            for signal in ProcessSignal.allCases {
                signals.addItem(ActionItem(signal.name) { model.send(signal, to: pids) })
            }
            menu.addItem(submenu("Send Signal", signals))

            if let single {
                let priorities = NSMenu()
                let levels: [(String, Int32)] = [
                    ("Highest (−20)", -20), ("High (−10)", -10), ("Normal (0)", 0), ("Low (10)", 10), ("Lowest (20)", 20),
                ]
                for (title, nice) in levels {
                    let item = ActionItem(title) { model.setNice(nice, for: single.pid) }
                    item.state = single.nice == nice ? .on : .off
                    priorities.addItem(item)
                }
                menu.addItem(submenu("Set Priority", priorities))
            }

            menu.addItem(.separator())
            if let single {
                menu.addItem(ActionItem("Get Info") { [weak self] in
                    self?.parent.selection = [single.pid]
                    self?.parent.onShowInspector()
                })
                menu.addItem(ActionItem("Sample Process") { model.sampleProcess(single.pid) })
                menu.addItem(ActionItem("Reveal in Finder") { model.revealInFinder(single.pid) })
                menu.addItem(ActionItem("Search Online") { model.searchOnline(single.pid) })

                let copy = NSMenu()
                copy.addItem(ActionItem("Name") { Self.copy(single.name) })
                copy.addItem(ActionItem("PID") { Self.copy(String(single.pid)) })
                if let path = single.executablePath {
                    copy.addItem(ActionItem("Path") { Self.copy(path) })
                }
                copy.addItem(ActionItem("Command Line") {
                    Self.copy(ProcessInspector.arguments(of: single.pid)?.commandLine ?? single.executablePath ?? single.name)
                })
                menu.addItem(submenu("Copy", copy))
            }
        }

        private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }

        private func confirm(_ message: String, detail: String, action: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { action() }
        }

        private static func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private func buildColumnMenu(_ menu: NSMenu, outline: NSOutlineView) {
            for column in outline.tableColumns where column.identifier.rawValue != ProcessColumn.name.rawValue {
                let item = ActionItem(column.title) { column.isHidden.toggle() }
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
        }
    }
}

// MARK: - Supporting views

/// Adds Delete-to-end-task to the outline view.
final class ProcessOutline: NSOutlineView {
    var onDelete: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

final class SectionCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class NameCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor
    func configure(process: ProcessSample, app: NSRunningApplication?, childCount: Int, isExpanded: Bool) {
        // Skip unchanged values: the table restyles visible rows every tick and
        // re-setting an image or string forces a redraw.
        let icon = IconCache.icon(for: process, app: app)
        if imageView?.image !== icon { imageView?.image = icon }
        let name = app?.localizedName ?? process.name
        if textField?.stringValue != name { textField?.stringValue = name }
        let color: NSColor = process.state == .stopped ? .secondaryLabelColor : .labelColor
        if textField?.textColor != color { textField?.textColor = color }
        var notes: [String] = []
        if childCount > 0, !isExpanded { notes.append("(\(childCount + 1))") }
        if process.state == .stopped { notes.append("Suspended") }
        if process.state == .zombie { notes.append("Zombie") }
        if process.isTranslated { notes.append("Rosetta") }
        let badgeText = notes.joined(separator: " · ")
        if badge.stringValue != badgeText { badge.stringValue = badgeText }
        if toolTip != process.executablePath { toolTip = process.executablePath }
    }
}

/// Value cell with an optional meter bar behind busy values.
final class ValueCell: NSTableCellView {
    private let bar = CALayer()
    private var fraction: Double = 0

    func setMeter(_ fraction: Double, color: NSColor?) {
        let shown = color == nil || fraction < 0.01 ? 0 : min(fraction, 1)
        // Busier rows get a deeper colour as well as a longer bar.
        bar.backgroundColor = color?.withAlphaComponent(0.20 + 0.40 * shown).cgColor
        guard shown != self.fraction else { return }
        self.fraction = shown
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let track = bounds.insetBy(dx: 2, dy: 3)
        bar.frame = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        bar.isHidden = fraction == 0
        CATransaction.commit()
    }

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        wantsLayer = true
        bar.cornerRadius = 3
        bar.isHidden = true
        layer?.addSublayer(bar)
        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
