import AppKit
import OTMKit

/// Adds Delete-to-end-task to the outline view, and fits the columns to its
/// width: Name takes the slack, and columns give way by priority before Name
/// goes below its minimum.
final class ProcessOutline: NSOutlineView {
    var onDelete: (() -> Void)?
    var onHiddenToFitChange: ((Set<ProcessColumn>) -> Void)?

    /// Columns switched off in the Columns menu.
    var userHidden: Set<ProcessColumn> = [] {
        didSet { if userHidden != oldValue { fitColumns() } }
    }

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
    /// then gives Name the slack. Cheap, and only touches columns that change.
    func fitColumns() {
        needsColumnFit = false
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

    /// After the user resized a column. Hiding columns under the pointer
    /// mid-drag would be jarring, so then only Name gives way.
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

    /// Gives Name whatever width the other columns leave, down to its
    /// minimum, so the table fills the view and only scrolls sideways when
    /// it has to. Done by hand because AppKit's first-column autoresizing
    /// missed resizes that came from SwiftUI.
    func fitNameColumn() {
        guard let name = outlineTableColumn, let clip = enclosingScrollView?.contentView else { return }
        let width = max(name.minWidth, (clip.bounds.width - otherColumnsWidth).rounded(.down))
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
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}
