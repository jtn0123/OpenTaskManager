import AppKit
import SwiftUI

/// Behind a SwiftUI `Table`: brings one row into view when asked, then
/// clears the request, so nothing scrolls again until the next one.
/// `ScrollViewProxy.scrollTo` didn't move the Startup table once it was on
/// screen, so this asks the AppKit table under it. A row out of view ends
/// up near the middle; one in view already stays where it is.
struct TableRowReveal: NSViewRepresentable {
    /// The row to bring into view, by its place in the table's rows.
    @Binding var row: Int?
    /// How many rows the table shows once it has caught up.
    var rows: Int

    func makeNSView(context: Context) -> TableRowRevealView {
        TableRowRevealView()
    }

    func updateNSView(_ view: TableRowRevealView, context: Context) {
        let binding = $row
        view.done = { if binding.wrappedValue != nil { binding.wrappedValue = nil } }
        view.rows = rows
        view.request = row
    }
}

final class TableRowRevealView: NSView {
    fileprivate var done: (() -> Void)?
    fileprivate var rows = 0
    fileprivate var request: Int? {
        didSet { if request != nil, request != oldValue { schedule(tries: 10) } }
    }

    private var isScheduled = false
    private var triesLeft = 0

    private func schedule(tries: Int) {
        triesLeft = tries
        guard !isScheduled else { return }
        isScheduled = true
        // After the SwiftUI update that asked has reached the table.
        DispatchQueue.main.async { [weak self] in self?.reveal() }
    }

    private func reveal() {
        isScheduled = false
        guard let row = request else { return }
        guard row < rows, window != nil, let table = nearestTable(), table.numberOfRows == rows else {
            // SwiftUI hands the table new rows an update or so after this
            // view's; past that, the row isn't coming.
            if triesLeft > 0, row < rows { schedule(tries: triesLeft - 1) } else { done?() }
            return
        }
        let shown = table.rows(in: table.visibleRect)
        // Rows at the edges may be half hidden, the top one under the header.
        let inView = row > shown.location && row < shown.location + shown.length - 1
        if !inView {
            // Each call scrolls only as far as it must: a row half a screen
            // past it, then one half a screen before, leave it in the middle.
            let half = max(shown.length / 2 - 1, 0)
            table.scrollRowToVisible(min(row + half, rows - 1))
            table.scrollRowToVisible(max(row - half, 0))
        }
        table.scrollRowToVisible(row)
        done?()
    }

    /// The table this view sits behind: the first one in the closest
    /// enclosing view that has one, never a sidebar's list further out.
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
