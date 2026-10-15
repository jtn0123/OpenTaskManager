import AppKit
import OTMKit

/// Adds Delete to end a task, and Option-Delete to force quit, to the
/// outline view, and fits the columns to its width: Name gets its preferred
/// width where there's room, and columns give way by priority before Name
/// goes below its minimum.
final class ProcessOutline: NSOutlineView {
    var onDelete: (() -> Void)?
    var onForceQuit: (() -> Void)?
    var onHiddenToFitChange: ((Set<ProcessColumn>) -> Void)?
    /// Called with Name's width once the user has dragged its edge.
    var onNameWidthChange: ((CGFloat) -> Void)?

    /// Name's width where the table has room for it. The figures then sit
    /// beside the names, and room left over goes after the last column
    /// rather than into a wide gap between the two. Dragging Name's edge sets it.
    var preferredNameWidth = ProcessColumn.name.width {
        didSet { if preferredNameWidth != oldValue { fitNameColumn() } }
    }

    /// Name's width as the user drags its edge, kept once the drag ends.
    private var draggedNameWidth: CGFloat?
    private static let widestName: CGFloat = 900

    /// Columns switched off in the Columns menu, and those this Mac doesn't
    /// report that weren't switched on anyway.
    var userHidden: Set<ProcessColumn> = [] {
        didSet { if userHidden != oldValue { fitColumns() } }
    }

    /// Columns this Mac has no figures for, named as such in the header's menu.
    var unreported: Set<ProcessColumn> = []

    /// Columns that are on but hidden because the table is too narrow for them.
    private(set) var hiddenToFit: Set<ProcessColumn> = []

    /// The columns need fitting on the next refresh: at first, after any
    /// saved layout is restored, and after a column was resized mid-drag,
    /// when only Name gave way.
    private(set) var needsColumnFit = true

    /// Width the columns that always stay need with Name at its narrowest,
    /// plus a scroller that takes room of its own. The others give way first.
    var minimumWidth: CGFloat {
        var width = ColumnFit.minimumWidth(wantedColumns) + edgeInset
        if let scrollView = enclosingScrollView, scrollView.scrollerStyle == .legacy,
           let scroller = scrollView.verticalScroller {
            width += scroller.frame.width
        }
        return width.rounded(.up)
    }

    /// The columns the user has on, in display order, with the room each
    /// takes: Name at its narrowest, the others at their current width.
    private var wantedColumns: [ColumnFit.Column<ProcessColumn>] {
        tableColumns.compactMap { tableColumn in
            guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue),
                  column == .name || !userHidden.contains(column) else { return nil }
            let width = column == .name ? tableColumn.minWidth : tableColumn.width
            return ColumnFit.Column(id: column, width: Double(width + intercellSpacing.width), priority: column.priority)
        }
    }

    /// Room the table takes beyond its columns and their gaps.
    private var edgeInset: CGFloat {
        guard let last = tableColumns.lastIndex(where: { !$0.isHidden }) else { return 0 }
        let columns = tableColumns.reduce(CGFloat(0)) { $0 + ($1.isHidden ? 0 : $1.width + intercellSpacing.width) }
        return max(rect(ofColumn: last).maxX - columns, 0)
    }

    /// Shows the columns the user has on that fit the width, hides the rest,
    /// then sizes Name. Cheap, and only touches columns that change.
    func fitColumns() {
        needsColumnFit = false
        if let dragged = draggedNameWidth {
            draggedNameWidth = nil
            preferredNameWidth = dragged
            onNameWidthChange?(dragged)
        }
        let width = enclosingScrollView?.contentView.bounds.width ?? 0
        // Before the first layout there's no width yet: show every column that's on.
        let hidden = width > 0 ? ColumnFit.hidden(wantedColumns, available: Double(width - edgeInset)) : []
        for tableColumn in tableColumns {
            guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue), column != .name else { continue }
            let isHidden = userHidden.contains(column) || hidden.contains(column)
            if tableColumn.isHidden != isHidden { tableColumn.isHidden = isHidden }
        }
        if hidden != hiddenToFit {
            hiddenToFit = hidden
            onHiddenToFitChange?(hidden)
        }
        fitNameColumn()
    }

    /// After Name was resized. A drag of its edge sets the width it keeps,
    /// once the drag ends; the fitting's own changes pass through.
    func nameWasResized() {
        guard let header = headerView, let name = outlineTableColumn, tableColumns.indices.contains(header.resizedColumn),
              tableColumns[header.resizedColumn] === name else { return }
        draggedNameWidth = min(max(name.width, name.minWidth), Self.widestName).rounded()
        needsColumnFit = true
    }

    /// After the user resized another column. Hiding columns under the
    /// pointer mid-drag would be jarring, so then only Name gives way.
    func columnWasResized() {
        if let header = headerView, header.resizedColumn >= 0 {
            needsColumnFit = true
            fitNameColumn()
        } else {
            fitColumns()
        }
    }

    /// Everything but Name: the end of the last visible column less Name's width.
    private var otherColumnsWidth: CGFloat {
        guard let name = outlineTableColumn, let last = tableColumns.lastIndex(where: { !$0.isHidden }) else { return 0 }
        return rect(ofColumn: last).maxX - name.width
    }

    /// Gives Name its preferred width, or what the other columns leave if
    /// that's less, down to its minimum, so the table only scrolls sideways
    /// when it has to. Done by hand because AppKit's first-column
    /// autoresizing missed resizes that came from SwiftUI. Not while the
    /// user drags Name's own edge.
    func fitNameColumn() {
        guard draggedNameWidth == nil, let name = outlineTableColumn, let clip = enclosingScrollView?.contentView else { return }
        let room = (clip.bounds.width - otherColumnsWidth).rounded(.down)
        let width = max(name.minWidth, min(preferredNameWidth, room))
        if name.width != width { name.width = width }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipViewResized(_ notification: Notification) {
        fitColumns()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
            if event.modifierFlags.contains(.option) { onForceQuit?() } else { onDelete?() }
        } else {
            super.keyDown(with: event)
        }
    }
}
