import AppKit
import OTMKit
import SwiftUI

/// Everything the table needs from SwiftUI on each refresh.
struct ProcessTableConfiguration {
    var nodes: [ProcessNode]
    /// Whole-system figures shown in the column headers, Windows-style.
    var headerTotals: [ProcessColumn: String]
    var hiddenColumns: HiddenProcessColumns
    /// Columns this Mac has no figures for, hidden unless switched on anyway.
    var unreportedColumns: Set<ProcessColumn>
    var cpuScale: CPUScale
    var heatmap: Bool
    var fastTierName: String
}

/// Lets the page act on the table directly: the inspector's Show Helpers
/// expands the selected row without waiting for the next refresh.
@MainActor
final class ProcessTableLink {
    fileprivate weak var coordinator: ProcessOutlineView.Coordinator?

    /// Expands the row for `pid` and scrolls the processes under it into view.
    func showNested(_ pid: Int32) {
        coordinator?.showNested(pid)
    }
}

struct ProcessOutlineView: NSViewRepresentable {
    /// Nil while the inspector covers the table: it's hidden and not updated.
    var configuration: ProcessTableConfiguration?
    @Binding var selection: Set<Int32>
    @Binding var sortKey: ProcessSortKey
    @Binding var ascending: Bool
    var model: AppModel
    var onShowInspector: () -> Void
    var onToggleColumn: (ProcessColumn) -> Void
    /// Called when the width the columns that always stay need (Name at its
    /// narrowest) changes, so the page knows when the inspector fits beside.
    var onMinimumWidthChange: (CGFloat) -> Void
    /// Called when the columns that are on but hidden to fit the width change,
    /// so the Columns menu can say so.
    var onHiddenToFitChange: (Set<ProcessColumn>) -> Void
    var link: ProcessTableLink
    /// Called when a process row is expanded or collapsed, with the rows now
    /// expanded, so the inspector can say what the selected row shows.
    var onExpandedChange: (Set<Int64>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ProcessOutline()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        // Name takes up the slack instead: see `ProcessOutline.fitNameColumn`.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.intercellSpacing = NSSize(width: ProcessColumn.spacing, height: 0)
        outline.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: ProcessHeaderCell.headerHeight))
        outline.rowHeight = 22
        outline.style = .fullWidth
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = true

        for column in ProcessColumn.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            let header = ProcessHeaderCell(textCell: column.title)
            header.alignment = column.isNumeric ? .right : .left
            tableColumn.headerCell = header
            tableColumn.headerToolTip = column.headerHelp
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            // Name fills whatever the others leave, so it isn't dragged.
            tableColumn.resizingMask = column == .name ? [] : .userResizingMask
            if let key = column.sortKey {
                // Numbers default to descending: biggest consumers first.
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: !column.isNumeric)
            }
            tableColumn.isHidden = column.hiddenByDefault
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        // Renamed from "ProcessOutline" when the columns got their minimum
        // widths, so saved layouts from before start from the new defaults.
        outline.autosaveName = "ProcessTable"
        outline.autosaveTableColumns = true

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onDelete = { [weak coordinator] in coordinator?.endSelected() }
        outline.onHiddenToFitChange = { [weak coordinator] in coordinator?.reportHiddenToFit($0) }
        let columnMenu = NSMenu()
        columnMenu.delegate = coordinator
        outline.headerView?.menu = columnMenu
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.outline = outline
        link.coordinator = coordinator

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
        guard let configuration else {
            scrollView.isHidden = true
            return
        }
        if scrollView.isHidden {
            scrollView.isHidden = false
            // Back from the full-width inspector: arrow keys work on the table again.
            if let outline = context.coordinator.outline { scrollView.window?.makeFirstResponder(outline) }
        }
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
        private var reportedMinimumWidth: CGFloat = 0
        /// A row whose nested rows to scroll into view once the table shows.
        private var revealing: Int64?

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
            guard let outline = outline as? ProcessOutline else { return }
            // Reloading mid-click would swallow the click; the next tick catches up.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            self.configuration = configuration
            syncSortDescriptor(outline)
            updateColumns(outline, configuration: configuration)

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
            if revealing != nil {
                // Back from the full-width inspector: once the table is laid out again.
                DispatchQueue.main.async { [weak self] in self?.scrollToReveal() }
            }
        }

        /// Expands the row for `pid`, and any section it's in, then scrolls
        /// the rows under it into view, now or once the table shows again.
        func showNested(_ pid: Int32) {
            guard let outline, let item = items[Int64(pid)], !item.children.isEmpty else { return }
            var ancestors: [Any] = []
            var ancestor = outline.parent(forItem: item)
            while let current = ancestor {
                ancestors.insert(current, at: 0)
                ancestor = outline.parent(forItem: current)
            }
            // Through the delegate, which records each as expanded by the user.
            ancestors.forEach { outline.expandItem($0) }
            outline.expandItem(item)
            revealing = item.id
            if outline.enclosingScrollView?.isHidden == false { scrollToReveal() }
        }

        /// The row's last nested row, then the row itself, so as many of them
        /// show as fit, with the row on top.
        private func scrollToReveal() {
            guard let id = revealing, let outline else { return }
            revealing = nil
            guard let item = items[id] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.scrollRowToVisible(min(row + item.children.count, outline.numberOfRows - 1))
            outline.scrollRowToVisible(row)
        }

        private func updateColumns(_ outline: ProcessOutline, configuration: ProcessTableConfiguration) {
            // Shows and hides columns only when the choice or what this Mac
            // reports changed, or a column was resized while the pointer was down.
            outline.unreported = configuration.unreportedColumns
            outline.userHidden = configuration.hiddenColumns.hidden(unreported: configuration.unreportedColumns)
            if outline.needsColumnFit { outline.fitColumns() }
            for (index, tableColumn) in outline.tableColumns.enumerated() {
                guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                let title = column == .topTier ? "\(configuration.fastTierName) %" : column.title
                if tableColumn.title != title { tableColumn.title = title }
                let total = configuration.headerTotals[column] ?? ""
                if let header = tableColumn.headerCell as? ProcessHeaderCell, header.total != total {
                    header.total = total
                    if !tableColumn.isHidden, let headerView = outline.headerView {
                        headerView.setNeedsDisplay(headerView.headerRect(ofColumn: index))
                    }
                }
            }
            let minimum = outline.minimumWidth
            guard minimum != reportedMinimumWidth else { return }
            reportedMinimumWidth = minimum
            let report = parent.onMinimumWidthChange
            // Not during SwiftUI's update.
            DispatchQueue.main.async { report(minimum) }
        }

        func reportHiddenToFit(_ hidden: Set<ProcessColumn>) {
            let report = parent.onHiddenToFitChange
            // The table fits its columns during SwiftUI's update too.
            DispatchQueue.main.async { report(hidden) }
        }

        /// Row operations that turn the outline's current rows into the new layout.
        private struct UpdatePlan {
            var changes: [(parent: Item?, changes: OrderedDiff.Changes)] = []
            /// Parents whose rows aren't on screen; their children are re-read instead.
            var hidden: [Item] = []
            /// Parents that gained their first child or lost their last, whose
            /// disclosure triangle comes or goes.
            var reshaped: [Item] = []
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
                        if previous.isEmpty != children.isEmpty { plan.reshaped.append(parent) }
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
            // Child counts on screen are restyled in place with the other
            // cells; only a disclosure triangle needs the row rebuilt.
            for parent in plan.reshaped { outline.reloadItem(parent, reloadChildren: false) }
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

        /// Name stays first: it holds the disclosure triangles and takes up the slack.
        func outlineView(_ outlineView: NSOutlineView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            columnIndex != 0 && newColumnIndex != 0
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
                let report = parent.onExpandedChange
                let rows = expanded
                // Not during the outline's own update.
                DispatchQueue.main.async { report(rows) }
            }
        }

        func outlineViewColumnDidResize(_ notification: Notification) {
            // A column the user dragged wider or narrower takes its room from
            // Name, and from the columns that give way once Name is at its narrowest.
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  column.identifier.rawValue != ProcessColumn.name.rawValue else { return }
            (outline as? ProcessOutline)?.columnWasResized()
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
            case .neuralMemory:
                // Memory, not load, so no meter. A row that never held any is "—", not 0 bytes.
                guard totals.hasHeldNeuralMemory else { return ("—", 0) }
                return (Format.bytes(totals.neuralMemory), 0)
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
    }
}

// MARK: - Context menus

extension ProcessOutlineView.Coordinator {
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
        if let outline = outline as? ProcessOutline, menu === outline.headerView?.menu {
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

    /// The same choices as the toolbar's Columns menu: ticked means on, even
    /// while the column is hidden to fit. A column this Mac doesn't report
    /// says so, unticked until switched on anyway.
    private func buildColumnMenu(_ menu: NSMenu, outline: ProcessOutline) {
        let toggle = parent.onToggleColumn
        for tableColumn in outline.tableColumns {
            guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue), column != .name else { continue }
            let title = column.menuTitle(hiddenToFit: outline.hiddenToFit.contains(column), unreported: outline.unreported.contains(column))
            let item = ActionItem(title) { toggle(column) }
            item.state = outline.userHidden.contains(column) ? .off : .on
            menu.addItem(item)
        }
        if !outline.hiddenToFit.isEmpty {
            menu.addItem(.separator())
            let note = NSMenuItem(title: ProcessColumn.hiddenToFitNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
    }
}

// MARK: - Supporting views

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
        label.font = .systemFont(ofSize: 12, weight: .semibold)
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
        let fill = color?.withAlphaComponent(0.20 + 0.40 * shown).cgColor
        if bar.backgroundColor != fill {
            // A standalone layer animates every change unless told not to.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.backgroundColor = fill
            CATransaction.commit()
        }
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
