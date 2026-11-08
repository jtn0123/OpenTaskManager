import AppKit
import SwiftUI

/// Places the main window at `MainWindowFrame.opening()` as it first gets
/// its content, before it shows, then saves its frame each time the user
/// moves or resizes it: at the end of a live resize, never during one, and
/// never while it's in full screen, which hands back the frame it had.
///
/// The keeper alone places the window. AppKit's frame autosave and macOS's
/// window restoration each kept a frame of their own and put it back after
/// the keeper's: restoration (whose saved state macOS 26 keeps out of reach,
/// in a daemon container) reopened every window at the size of the last one
/// killed, a narrow screenshot run's included. So the window keeps no
/// autosave name, isn't restorable, and the app ignores any state saved
/// before (`MainWindowFrame.ignoreSavedWindowState`).
struct MainWindowFrameKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowFrameView {
        MainWindowFrameView()
    }

    func updateNSView(_ view: MainWindowFrameView, context: Context) {}
}

final class MainWindowFrameView: NSView {
    private weak var placed: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var inFullScreen = false
    private var frameBeforeFullScreen: CGRect?

    // Never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== placed else { return }
        stopObserving()
        placed = window
        guard let window else { return }
        window.setFrameAutosaveName("")
        window.isRestorable = false
        window.setFrame(MainWindowFrame.opening(), display: true)
        inFullScreen = window.styleMask.contains(.fullScreen)
        observe(window)
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let saves: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didEndLiveResizeNotification]
        for name in saves {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterFullScreen() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.exitFullScreen() }
        })
    }

    private func enterFullScreen() {
        inFullScreen = true
        frameBeforeFullScreen = placed?.frame
    }

    /// Leaving full screen, SwiftUI put back the frame it gave the window as
    /// it opened, not one the keeper (or Return to Default Size) set since;
    /// a size the user dragged came back. The frame from just before full
    /// screen is put back either way.
    private func exitFullScreen() {
        inFullScreen = false
        if let window = placed, let frame = frameBeforeFullScreen, window.frame != frame {
            window.setFrame(frame, display: true)
        }
        frameBeforeFullScreen = nil
        save()
    }

    private func save() {
        guard let window = placed, !inFullScreen, !window.inLiveResize, !window.isMiniaturized else { return }
        MainWindowFrame.save(window.frame)
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
