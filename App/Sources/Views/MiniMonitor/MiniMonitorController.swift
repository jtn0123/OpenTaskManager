import AppKit
import OTMKit
import SwiftUI

/// Shows the floating mini monitor while `Settings.miniMonitorShown` is on,
/// and keeps it as its settings say: its level, its opacity, and its corner
/// of its display. A drag drops it anywhere; once the button is up it goes to
/// the nearest corner of the display it's on, which it then keeps when its
/// size, the Dock or the displays change.
@MainActor
final class MiniMonitorController: NSObject {
    private weak var model: AppModel?
    private var panel: MiniMonitorPanel?
    private var backing: MiniMonitorBacking?
    private var observers: [NSObjectProtocol] = []
    /// What was last applied, so the many unrelated defaults changes cost a comparison.
    private var applied: Look?
    /// Set while the panel is moved here, so its move isn't taken for a drag.
    private var isPlacing = false
    private var settleTimer: Timer?

    private struct Look: Equatable {
        var shown: Bool
        var level: MiniMonitorLevel
        var corner: ScreenCorner
        var display: String?
        var opacity: Double
        var solidUnderPointer: Bool
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        sync()
    }

    private func currentLook() -> Look {
        Look(shown: Settings.miniMonitorShown.get(), level: Settings.miniMonitorLevel.get(),
             corner: Settings.miniMonitorCorner.get(), display: Settings.miniMonitorDisplay.get(),
             opacity: min(max(Settings.miniMonitorOpacity.get(), 0.3), 1),
             solidUnderPointer: Settings.miniMonitorSolidUnderPointer.get())
    }

    private func sync() {
        let look = currentLook()
        guard look != applied else { return }
        let previous = applied
        applied = look
        model?.miniMonitor.isOn = look.shown
        guard look.shown else {
            settleTimer?.invalidate()
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        panel.apply(look.level)
        backing?.restingOpacity = look.opacity
        backing?.solidUnderPointer = look.solidUnderPointer
        if previous?.shown != true || previous?.corner != look.corner || previous?.display != look.display {
            place(animated: previous?.shown == true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> MiniMonitorPanel {
        let root = MiniMonitorView { [weak self] size in self?.contentSizeChanged(size) }
        let hosting = NSHostingView(rootView: root.environment(model))
        // Its first size from SwiftUI, then the panel follows the content's
        // reported size itself, keeping its corner where AppKit would keep its foot.
        hosting.frame.size = hosting.fittingSize
        hosting.sizingOptions = []
        let backing = MiniMonitorBacking(content: hosting)
        let panel = MiniMonitorPanel(content: backing)
        panel.setAccessibilityLabel("Mini monitor")
        panel.doubleClicked = { WindowOpener.showMainWindow() }
        panel.menuRequested = { [weak self] event in self?.showMenu(for: event) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        })
        self.panel = panel
        self.backing = backing
        return panel
    }

    // MARK: - Placement

    /// The display it was placed on, or the main one if that isn't connected.
    private var screen: NSScreen? {
        let display = applied?.display
        return NSScreen.screens.first { display != nil && $0.displayUUID == display } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func place(size: CGSize? = nil, animated: Bool = false) {
        guard let panel, let screen, let corner = applied?.corner else { return }
        let frame = MiniMonitorPlacement.frame(size: size ?? panel.frame.size, corner: corner, in: screen.visibleFrame)
        guard frame != panel.frame else { return }
        isPlacing = true
        panel.setFrame(frame, display: true, animate: animated)
        isPlacing = false
    }

    /// Fits the panel to its content, keeping its corner.
    private func contentSizeChanged(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard size != panel.frame.size else { return }
        place(size: size)
    }

    private func panelMoved() {
        guard !isPlacing else { return }
        settleTimer?.invalidate()
        // The window server moves it while the button is down; settle once it's up.
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func settle() {
        guard let panel else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            panelMoved()
            return
        }
        let middle = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) ?? panel.screen else { return }
        let corner = MiniMonitorPlacement.corner(nearest: panel.frame, in: screen.visibleFrame)
        let display = screen.displayUUID
        // The look first, so the defaults change this makes finds nothing new to do.
        applied?.corner = corner
        applied?.display = display
        Settings.miniMonitorCorner.set(corner)
        if let display { Settings.miniMonitorDisplay.set(display) }
        place(animated: true)
    }

    // MARK: - Menu

    private func showMenu(for event: NSEvent) {
        guard let view = panel?.contentView, let look = applied else { return }
        let menu = NSMenu()
        menu.addItem(item("Open OpenTaskManager", #selector(openMain)))
        menu.addItem(.separator())
        for level in MiniMonitorLevel.allCases {
            let entry = item(level.menuTitle, #selector(chooseLevel(_:)))
            entry.representedObject = level.rawValue
            entry.state = level == look.level ? .on : .off
            menu.addItem(entry)
        }
        let corners = NSMenu()
        for corner in ScreenCorner.allCases {
            let entry = item(corner.menuTitle, #selector(chooseCorner(_:)))
            entry.representedObject = corner.rawValue
            entry.state = corner == look.corner ? .on : .off
            corners.addItem(entry)
        }
        let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        move.submenu = corners
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(item("Mini Monitor Settings…", #selector(openSettings)))
        menu.addItem(item("Hide Mini Monitor", #selector(hide)))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMain() { WindowOpener.showMainWindow() }

    @objc private func chooseLevel(_ sender: NSMenuItem) {
        guard let level = (sender.representedObject as? String).flatMap(MiniMonitorLevel.init(rawValue:)) else { return }
        Settings.miniMonitorLevel.set(level)
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        guard let corner = (sender.representedObject as? String).flatMap(ScreenCorner.init(rawValue:)) else { return }
        Settings.miniMonitorCorner.set(corner)
    }

    /// The app menu's Settings… item: SwiftUI opens its Settings scene only
    /// from a view or that item.
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        menu.performActionForItem(at: index)
    }

    @objc private func hide() { Settings.miniMonitorShown.set(false) }
}

private extension MiniMonitorLevel {
    var menuTitle: String {
        switch self {
        case .aboveWindows: "Above Other Windows"
        case .amongWindows: "Among Other Windows"
        case .desktop: "On the Desktop"
        }
    }
}

private extension ScreenCorner {
    var menuTitle: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}
