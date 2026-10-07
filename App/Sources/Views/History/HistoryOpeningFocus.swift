import AppKit
import OTMKit
import SwiftUI

/// Opens the History page with nothing ringed. When the page appears, or
/// the window first becomes key with it showing, AppKit hands the focus to
/// the first control in the key view loop, the range picker, which then
/// wears a focus ring as if the user had tabbed to it. This takes such a
/// focus away (`OpeningFocus` decides), looking a few times over the first
/// seconds as SwiftUI may move the focus a moment late. Once the user
/// presses a key or clicks, it stops looking, and focus outside the page
/// (the sidebar's list, the toolbar) or in a text field is left alone, as
/// `PageFocus` leaves it. Sits in the page's background, filling it.
struct HistoryOpeningFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> HistoryOpeningFocusView {
        HistoryOpeningFocusView()
    }

    func updateNSView(_ view: HistoryOpeningFocusView, context: Context) {}
}

final class HistoryOpeningFocusView: NSView {
    /// When to look after the page appears, in seconds since.
    private static let looks: [Double] = [0, 0.1, 0.25, 0.5, 1, 2]

    private var looking: Task<Void, Never>?
    private var keyObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var userActed = false

    // Never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        userActed = false
        if window.isKeyWindow {
            look()
        } else {
            // Not key yet (the app launching into this page): look when it first becomes key.
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                                 queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameKey() }
            }
        }
    }

    private func windowBecameKey() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        look()
    }

    private func look() {
        stop()
        // Any key or click from here on is the user's own doing.
        let acts: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: acts) { [weak self] event in
            MainActor.assumeIsolated { self?.userActed = true }
            return event
        }
        looking = Task { [weak self] in
            var elapsed = 0.0
            for time in Self.looks {
                try? await Task.sleep(for: .seconds(time - elapsed))
                elapsed = time
                guard !Task.isCancelled, let self, !self.settle() else { break }
            }
            self?.stop()
        }
    }

    private func stop() {
        looking?.cancel()
        looking = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    /// Takes a control's focus away if `OpeningFocus` says so; true once there's no need to look again.
    private func settle() -> Bool {
        guard let window else { return true }
        let responder = window.firstResponder
        let holder = Self.holder(responder, in: window)
        if OpeningFocus.clears(holder, onPage: isOnPage(responder), userActed: userActed) {
            window.makeFirstResponder(nil)
        }
        return OpeningFocus.isSettled(holder, userActed: userActed)
    }

    private static func holder(_ responder: NSResponder?, in window: NSWindow) -> OpeningFocus.Holder {
        guard let view = responder as? NSView, view !== window.contentView else { return .nothing }
        if view is NSText || view is NSTextField { return .text }
        return view is NSControl ? .control : .other
    }

    /// Whether `responder` is a view within the page's frame, rather than in the sidebar or the toolbar.
    private func isOnPage(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, let content = window?.contentView, view.isDescendant(of: content),
              !view.isHiddenOrHasHiddenAncestor else { return false }
        let page = convert(bounds, to: nil)
        let frame = view.convert(view.bounds, to: nil)
        return page.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
