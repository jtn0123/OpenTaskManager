import AppKit
import OTMKit
import SwiftUI

/// While the sidebar is hidden, gives the keyboard focus to the page: its
/// main table on the pages built around one, otherwise nothing, and never
/// the toolbar's sidebar button, where it fell when the sidebar's list went
/// (ringed, with keyboard navigation or Full Keyboard Access on). It looks
/// when the window first becomes key, when the sidebar hides and when the
/// page changes behind it, and a few times over the next seconds, since a
/// table may arrive late (Startup, Apps, Drivers and Connections read their
/// lists first) and SwiftUI may move the focus a moment after a change.
/// Focus the page or the user put somewhere is never moved, and with the
/// sidebar shown nothing is done: its list keeps the focus it gets.
struct PageFocus: NSViewRepresentable {
    var page: Page
    var sidebarShown: Bool

    func makeNSView(context: Context) -> PageFocusView {
        PageFocusView()
    }

    func updateNSView(_ view: PageFocusView, context: Context) {
        view.update(page: page, sidebarShown: sidebarShown)
    }
}

final class PageFocusView: NSView {
    /// The pages whose main table takes the focus.
    private static let tablePages: Set<Page> = [.processes, .startup, .apps, .drivers, .connections]
    /// When to look after a change, in seconds since it.
    private static let looks: [Double] = [0, 0.1, 0.25, 0.5, 1, 2, 3, 5]

    private var page: Page?
    private var sidebarShown = true
    private var looking: Task<Void, Never>?
    private var keyObserver: NSObjectProtocol?
    private var becameKey = false

    // Never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(page: Page, sidebarShown: Bool) {
        let changed = page != self.page || sidebarShown != self.sidebarShown
        self.page = page
        self.sidebarShown = sidebarShown
        if sidebarShown {
            looking?.cancel()
        } else if changed, becameKey {
            look()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else {
            looking?.cancel()
            return
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowBecameKey() }
        }
        if window.isKeyWindow { windowBecameKey() }
    }

    /// The first time only: later, the focus comes back where the user left it.
    private func windowBecameKey() {
        guard !becameKey else { return }
        becameKey = true
        if !sidebarShown { look() }
    }

    private func look() {
        looking?.cancel()
        looking = Task { [weak self] in
            var elapsed = 0.0
            for time in Self.looks {
                try? await Task.sleep(for: .seconds(time - elapsed))
                elapsed = time
                guard !Task.isCancelled, let self, !self.settle() else { return }
            }
        }
    }

    /// Puts the focus where it belongs, if it isn't there yet; true once it is.
    private func settle() -> Bool {
        guard let window, let page, !sidebarShown else { return true }
        let place = Self.place(of: window.firstResponder, in: window)
        let table = Self.tablePages.contains(page) ? Self.mainTable(in: window.contentView) : nil
        let move = HiddenSidebarFocus.move(from: place, tableReady: table != nil)
        switch move {
        case .keep: break
        case .table: window.makeFirstResponder(table)
        case .clear: window.makeFirstResponder(nil)
        }
        return HiddenSidebarFocus.isSettled(move, from: place)
    }

    private static func place(of responder: NSResponder?, in window: NSWindow) -> HiddenSidebarFocus.Place {
        guard let view = responder as? NSView, let content = window.contentView, view !== content else { return .nowhere }
        // A search field being typed in, in the toolbar or on the page.
        if view is NSText || view is NSTextField { return .content }
        // The toolbar lives in the window's title bar, outside its content.
        guard view.isDescendant(of: content) else { return .toolbarButton }
        return view.isHiddenOrHasHiddenAncestor ? .hiddenSidebar : .content
    }

    /// The page's first table, if it's on screen: one covered by its
    /// details pane is moved out of the window and doesn't count. The
    /// hidden sidebar's list is skipped with the rest of the column.
    private static func mainTable(in view: NSView?) -> NSTableView? {
        guard let view, let table = firstTable(in: view), !table.visibleRect.isEmpty, table.acceptsFirstResponder else { return nil }
        return table
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        guard !view.isHidden else { return nil }
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}
