import AppKit
import SwiftUI

extension View {
    /// Keeps a SwiftUI `Table` only as tall as its rows, so the system
    /// doesn't stripe empty space under the last one, which reads as rows
    /// still loading. With more rows than room, it fills and scrolls as usual.
    ///
    /// Measured from the `NSTableView` behind the table when the row count
    /// or the table's size changes, never per frame.
    func fitsTableToRows(_ rows: Int) -> some View {
        modifier(TableFit(rows: rows))
    }
}

/// What the table needs to show every row without scrolling.
private struct TableNeeds: Equatable {
    /// The header, the rows and room to spare under them.
    var height: CGFloat
    /// The room under the last row, which the system stripes like a row.
    var spare: CGFloat
    /// The table has that height now, so nothing scrolls.
    var showsEveryRow: Bool
}

private struct TableFit: ViewModifier {
    var rows: Int
    @State private var needs: TableNeeds?

    func body(content: Content) -> some View {
        let trim = needs.map { $0.showsEveryRow ? $0.spare : 0 } ?? 0
        content
            .background(TableFitProbe(rows: rows, needs: $needs))
            .frame(maxWidth: .infinity, maxHeight: needs?.height ?? .infinity)
            // The table keeps the room it needs, so it never scrolls, and
            // what's under its last row is cut off.
            .padding(.bottom, -trim)
            .clipped()
    }
}

private struct TableFitProbe: NSViewRepresentable {
    var rows: Int
    @Binding var needs: TableNeeds?

    func makeNSView(context: Context) -> TableFitProbeView {
        TableFitProbeView()
    }

    func updateNSView(_ view: TableFitProbeView, context: Context) {
        let binding = $needs
        view.report = { measured in
            if binding.wrappedValue != measured { binding.wrappedValue = measured }
        }
        view.rows = rows
    }
}

final class TableFitProbeView: NSView {
    fileprivate var report: ((TableNeeds) -> Void)?
    /// Setting it measures again, once AppKit has caught up with the rows.
    var rows = 0 {
        didSet { if rows != oldValue { scheduleMeasure() } }
    }

    private weak var table: NSTableView?
    private var isScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleMeasure()
    }

    @objc private func scrollViewResized(_ notification: Notification) {
        scheduleMeasure()
    }

    private func scheduleMeasure() {
        guard !isScheduled else { return }
        isScheduled = true
        // After the SwiftUI update that changed the rows has reached the table.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isScheduled = false
            measure()
        }
    }

    private func measure() {
        guard window != nil, let table = table ?? nearestTable(), let scrollView = table.enclosingScrollView else { return }
        if self.table !== table {
            self.table = table
            // A new width can bring in a horizontal scroller, and the height
            // decides whether every row shows.
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized),
                                                   name: NSView.frameDidChangeNotification, object: scrollView)
        }
        let count = table.numberOfRows
        let header = table.headerView?.frame.height ?? 0
        let rows = count > 0 ? table.rect(ofRow: count - 1).maxY : 0
        // A row's worth of room to spare, which is cut off again. Sized to
        // the rows exactly, a table can tip into showing scrollers (with
        // legacy scrollers, both, as one squeezes the other) and stay there.
        let spare = count > 0 ? table.rect(ofRow: 0).maxY : 0
        let height = ceil(header + rows + spare)
        report?(TableNeeds(height: height, spare: spare, showsEveryRow: scrollView.frame.height >= height - 0.5))
    }

    /// The table this probe sits behind: the first one found in the
    /// closest enclosing view that has one, so a sidebar's list further out
    /// is never mistaken for it.
    private func nearestTable() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = Self.firstTable(in: view) { return table }
            ancestor = view.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}
