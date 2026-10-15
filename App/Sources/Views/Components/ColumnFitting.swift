import AppKit
import OTMKit
import SwiftUI

/// A column of a SwiftUI `Table` that gives way when the table runs short of
/// room, lowest priority first (`ColumnFit` in OTMKit, as on the Processes
/// table), so the columns that say what a row is keep their width. The raw
/// value is the column's customization ID.
protocol FittingColumn: Hashable, CaseIterable, RawRepresentable where RawValue == String, AllCases == [Self] {
    /// Narrowest the column gets, and the width it starts at before the table shares out its room.
    var minWidth: CGFloat { get }
    /// Short values stop growing here; nil for the columns that take the rest.
    var maxWidth: CGFloat? { get }
    /// Lower priorities give way first; nil for a column that always stays.
    var priority: Int? { get }
}

extension FittingColumn {
    /// The columns that give way when there isn't room.
    static var givingWay: Set<Self> { Set(allCases.filter { $0.priority != nil }) }

    /// NSTableView's gap between columns, which SwiftUI's table keeps.
    private static var spacing: CGFloat { 17 }

    /// The table's side insets, and a vertical scroller where scroll bars
    /// always show (a mouse rather than a trackpad), which takes room of its own.
    @MainActor private static var chrome: CGFloat {
        2 * 10 + (NSScroller.preferredScrollerStyle == .legacy ? 16 : 0)
    }

    /// The columns that are on, in order, with the room each needs: its
    /// content's where that's been measured (`ColumnWidths`), else its own.
    private static func wanted(userHidden: Set<Self>, widths: ColumnWidths<Self> = .init()) -> [ColumnFit.Column<Self>] {
        allCases.filter { !userHidden.contains($0) }.map {
            ColumnFit.Column(id: $0, width: Double(widths.min($0) + spacing), priority: $0.priority)
        }
    }

    /// Columns that are on but don't fit a table `width` points wide.
    @MainActor static func hiddenToFit(width: CGFloat, userHidden: Set<Self>, widths: ColumnWidths<Self> = .init()) -> Set<Self> {
        ColumnFit.hidden(wanted(userHidden: userHidden, widths: widths), available: Double(width - chrome))
    }

    /// Narrowest the table goes without scrolling sideways, once every
    /// column that can has given way. Beside the details pane it never gets less.
    @MainActor static func tableMinimum(userHidden: Set<Self>) -> CGFloat {
        CGFloat(ColumnFit.minimumWidth(wanted(userHidden: userHidden))) + chrome
    }
}

extension TableColumn where Label == Text {
    /// The column's widths and customization ID. Which columns show is the
    /// page's and the width's, so the header's menu leaves it alone.
    ///
    /// Columns start at their narrowest and the table shares out the rest.
    /// A table with column customization keeps its starting widths when they
    /// add up to more than its room, and scrolls sideways for good, so
    /// starting any wider can push the last columns out of a narrow window.
    ///
    /// With `widths`, a column whose values shouldn't be cut starts at their
    /// width, and gives way whole rather than cut them; one of short values
    /// stops growing where they end.
    @MainActor func fitted<Column: FittingColumn>(_ column: Column, widths: ColumnWidths<Column> = .init())
        -> some TableColumnContent<RowValue, Sort> {
        width(min: widths.min(column), ideal: widths.min(column), max: widths.max(column))
            .customizationID(column.rawValue)
            .disabledCustomizationBehavior(.visibility)
    }
}

/// Widths measured from a table's content (`ColumnContent`), in place of
/// its columns' own: a narrowest for the columns whose values shouldn't be
/// cut, and a widest for those that should stop where their values do.
struct ColumnWidths<Column: FittingColumn>: Equatable {
    var minimums: [Column: CGFloat] = [:]
    var maximums: [Column: CGFloat] = [:]
    /// Room for the long forms of columns that have short ones for when
    /// they're narrow ("System agent" for "Agent", "Running PID 501" for
    /// "Running"), in the order they get it: `TableColumnFitter` makes each
    /// its column's narrowest while that costs no column its place.
    var longForms: [LongForm] = []

    struct LongForm: Equatable {
        var column: Column
        var width: CGFloat
    }

    func min(_ column: Column) -> CGFloat { minimums[column] ?? column.minWidth }

    /// Never under the column's narrowest.
    func max(_ column: Column) -> CGFloat? {
        (maximums[column] ?? column.maxWidth).map { Swift.max($0, min(column)) }
    }

    /// With `columns` kept wide enough for their long forms.
    func widened(_ columns: Set<Column>) -> Self {
        var widths = self
        for form in longForms where columns.contains(form.column) {
            widths.minimums[form.column] = Swift.max(form.width, min(form.column))
        }
        return widths
    }
}

/// Watches a table's width and reports the columns that don't fit it, and
/// those with long forms (`ColumnWidths.longForms`) that have room for them
/// without another column giving way. Put it in the table's background, so
/// resizing the window re-runs this, not the rows, and the columns change
/// only when one has to give way or a long form comes or goes.
struct TableColumnFitter<Column: FittingColumn>: View {
    var userHidden: Set<Column>
    var widths = ColumnWidths<Column>()
    @Binding var hiddenToFit: Set<Column>
    var widened: Binding<Set<Column>> = .constant([])
    @State private var width: CGFloat?

    var body: some View {
        let fitted = width.map { Column.hiddenToFit(width: $0, userHidden: userHidden, widths: widths) }
        // Each in turn, kept if the same columns still fit with it.
        let roomy = width.map { width in
            widths.longForms.reduce(into: Set<Column>()) { roomy, form in
                let tried = roomy.union([form.column])
                if Column.hiddenToFit(width: width, userHidden: userHidden, widths: widths.widened(tried)) == fitted {
                    roomy = tried
                }
            }
        }
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: fitted, initial: true) {
                if let fitted, fitted != hiddenToFit { hiddenToFit = fitted }
            }
            .onChange(of: roomy, initial: true) {
                if let roomy, roomy != widened.wrappedValue { widened.wrappedValue = roomy }
            }
    }
}

/// Brings the shown columns back inside the table's edge once some have
/// hidden to fit. A table already running past its edge, as it does for a
/// moment when the details pane opens beside it, gives a hidden column's
/// width to the others instead of narrowing, and would go on scrolling
/// sideways. Runs when the columns shown or the table's size change, never
/// on a refresh of the rows, and leaves a table that fits alone.
struct TableColumnSqueeze: NSViewRepresentable {
    /// How many columns the table has in all, which tells it from other tables nearby.
    var columns: Int
    /// How many it has been told to show.
    var shown: Int

    func makeNSView(context: Context) -> TableColumnSqueezeView {
        TableColumnSqueezeView()
    }

    func updateNSView(_ view: TableColumnSqueezeView, context: Context) {
        view.columns = columns
        view.shown = shown
    }
}

final class TableColumnSqueezeView: NSView {
    /// Setting it fits the columns again, once the table shows that many.
    var shown = 0 {
        didSet { if shown != oldValue { scheduleFit() } }
    }

    /// How many columns its table has in all.
    var columns = 0
    private weak var table: NSTableView?
    /// The table's width when last seen, so rows coming and going leave it be.
    private var tableWidth: CGFloat = 0
    private var isScheduled = false
    /// Tries left to find the table showing `shown` columns: SwiftUI makes
    /// it, and hides its columns, an update or two after this view's.
    private var triesLeft = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFit()
    }

    @objc private func scrollViewResized(_ notification: Notification) {
        scheduleFit()
    }

    /// The table widened its columns itself: it hands a column's room to the
    /// others as SwiftUI hides it, up to their widest, after the fit that
    /// left the room.
    @objc private func tableResized(_ notification: Notification) {
        guard let table, table.frame.width != tableWidth else { return }
        tableWidth = table.frame.width
        scheduleFit()
    }

    private func scheduleFit() {
        triesLeft = 10
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    private func fit() {
        isScheduled = false
        // A column the user is dragging is theirs to size.
        guard window != nil, table?.headerView?.resizedColumn ?? -1 < 0 else { return }
        guard let table = table ?? nearestTable(),
              let scrollView = table.enclosingScrollView,
              table.tableColumns.filter({ !$0.isHidden }).count == shown
        else {
            retry()
            return
        }
        if self.table !== table {
            self.table = table
            // The clip view, which narrows when the window or the details
            // pane does, and when a scroller comes in.
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized),
                                                   name: NSView.frameDidChangeNotification, object: scrollView.contentView)
            table.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(tableResized),
                                                   name: NSView.frameDidChangeNotification, object: table)
        }
        // Less the insets: in a window whose sidebar floats over the page,
        // the scroll view runs on under it and insets its content past it.
        let insets = scrollView.contentView.contentInsets
        let excess = table.frame.width - (scrollView.contentView.bounds.width - insets.left - insets.right)
        guard excess > 0 else { return }
        let columns = table.tableColumns.filter { !$0.isHidden }
        // By whole points: widths land on half points, and half a point
        // over is enough for a scroller.
        let widths = ColumnFit.narrowed(widths: columns.map { Double($0.width) },
                                        minimums: columns.map { Double($0.minWidth) },
                                        by: Double(excess.rounded(.up)))
        for (column, width) in zip(columns, widths) {
            column.width = CGFloat(width)
        }
    }

    private func retry() {
        guard triesLeft > 0, !isScheduled else { return }
        triesLeft -= 1
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fit() }
    }

    /// The table this one sits behind: the first with that many columns in
    /// the closest enclosing view that has one.
    private func nearestTable() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = table(in: view) { return table }
            ancestor = view.superview
        }
        return nil
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.tableColumns.count == columns { return table }
        for subview in view.subviews {
            if let table = table(in: subview) { return table }
        }
        return nil
    }
}
