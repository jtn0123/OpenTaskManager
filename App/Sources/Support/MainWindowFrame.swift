import AppKit
import OTMKit

/// The main window's size and place, kept in `Settings.mainWindowFrame`
/// rather than AppKit's frame autosave. SwiftUI's window wrote AppKit's
/// "NSWindow Frame main" once, as it opened, and never again, so the window
/// never kept a size the user gave it, while one from a run's launch
/// arguments (a narrow screenshot's 820 points) stuck: every later window
/// opened at the minimum width with its sidebar hidden.
@MainActor
enum MainWindowFrame {
    /// `-openWindowFrame "x y width height"` places the window for one run,
    /// for screenshots; nothing it does there is saved.
    static let launchArgument = "openWindowFrame"
    /// AppKit's autosaved frame, which no longer opens the window.
    static let appKitKey = "NSWindow Frame main"
    /// AppKit's switch for ignoring saved window state at launch, the
    /// `-ApplePersistenceIgnoreState YES` argument's.
    static let ignoresSavedStateKey = "ApplePersistenceIgnoreState"

    /// The frame the window opens at: the launch argument's, else the saved
    /// frame put back on a screen that's still there, else the default on
    /// `main`, which is nil only with no screen at all.
    static func opening(defaults: UserDefaults = .standard, arguments: [String: Any] = LaunchArgument.domain,
                        screens: [CGRect] = screenFrames(), main: CGRect? = mainScreenFrame()) -> CGRect {
        if let requested = WindowPlacement.frame(from: LaunchArgument.string(launchArgument, in: arguments)) {
            return requested
        }
        let saved = WindowPlacement.frame(from: Settings.mainWindowFrame.get(in: defaults))
        guard let main else { return saved ?? CGRect(origin: .zero, size: WindowPlacement.defaultMinimum) }
        return WindowPlacement.openingFrame(saved: saved, screens: screens, main: main)
    }

    /// Keeps `frame` for the next opening, unless a launch argument placed
    /// the window this run. An unchanged frame isn't written again.
    static func save(_ frame: CGRect, defaults: UserDefaults = .standard, arguments: [String: Any] = LaunchArgument.domain) {
        guard LaunchArgument.string(launchArgument, in: arguments) == nil else { return }
        let value = WindowPlacement.string(frame)
        if Settings.mainWindowFrame.get(in: defaults) != value {
            Settings.mainWindowFrame.set(value, in: defaults)
        }
    }

    /// Drops AppKit's copy, and has AppKit ignore window state macOS saved
    /// for an earlier run, which it otherwise applied after `opening`'s frame
    /// (the register domain, so it lasts only for this run). Call before any
    /// window opens.
    static func ignoreSavedWindowState(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: appKitKey)
        defaults.register(defaults: [ignoresSavedStateKey: true])
    }

    /// Window > Return to Default Size: the size a first window gets on the
    /// screen the window is on, wherever it was moved or resized to.
    static func returnToDefault() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              !window.styleMask.contains(.fullScreen),
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrame(WindowPlacement.defaultFrame(in: screen), display: true, animate: true)
    }

    /// Every screen's usable area, under the menu bar and beside the Dock.
    static func screenFrames() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    /// Where a new window goes: the screen with the key window, else the one with the menu bar.
    static func mainScreenFrame() -> CGRect? {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }
}
