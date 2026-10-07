import AppKit
import OTMKit
import SwiftUI

/// The menu bar item, kept by hand rather than with `MenuBarExtra`. Every
/// refresh, MenuBarExtra rebuilt its SwiftUI label, re-measured the item and
/// handed it over again, which cost about as much as the menu bar redrawing
/// the new picture; here a refresh only swaps the image, and only when the
/// picture changed. Clicking it shows the same summary panel.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    static let shared = StatusItemController()

    /// Set before launch finishes; the item follows it from then on.
    var model: AppModel?
    private var item: NSStatusItem?
    private var panel: SummaryPanel?
    private var outsideClicks: Any?
    /// When the panel last closed. A click on the item that closed it (by
    /// taking focus first) shouldn't open it again straight away.
    private var closedAt = Date.distantPast
    private var observing = false

    func start() {
        sync()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StatusItemController.shared.sync() }
        }
    }

    /// Adds or removes the item to match the Settings switch.
    private func sync() {
        let shown = UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
        if shown, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "OpenTaskManager"
            item.button?.target = self
            item.button?.action = #selector(toggle)
            self.item = item
            observe()
        } else if !shown, let item {
            close()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Redraws the item now, and again whenever the CPU figures change.
    private func observe() {
        guard !observing, let model, item != nil else { return }
        observing = true
        withObservationTracking {
            update(history: model.cpuHistory.values, usage: model.snapshot?.cpu.usage ?? 0)
        } onChange: {
            Task { @MainActor in
                let controller = StatusItemController.shared
                controller.observing = false
                controller.observe()
            }
        }
    }

    private func update(history: [Double], usage: Double) {
        guard let button = item?.button else { return }
        let image = MenuBarIcon.image(history: history, usage: usage)
        guard button.image !== image else { return }
        button.image = image
        button.setAccessibilityLabel("CPU \(Format.percent(usage))")
    }

    // MARK: - Panel

    @objc private func toggle() {
        if panel?.isVisible == true {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            show()
        }
    }

    private func show() {
        guard let model, let button = item?.button, let buttonWindow = button.window else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        // A fresh view each time: a closed panel shouldn't keep following the model.
        let host = NSHostingView(rootView: MenuBarSummary(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        // Under the item, its leading edges lined up, kept on screen.
        let size = host.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.minX, screen.minX + 6), screen.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 5 - size.height, width: size.width, height: size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        // No focus ring on the first button until the keyboard asks for one.
        panel.makeFirstResponder(nil)
        panel.invalidateShadow()
        button.highlight(true)

        // Clicks in other apps and on the desktop; a click in one of ours takes focus instead.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { StatusItemController.shared.close() }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        item?.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        closedAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> SummaryPanel {
        let panel = SummaryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    /// Rounds the panel's corners, and so its shadow.
    private static let roundedMask: NSImage = {
        let radius: CGFloat = 10
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

/// A borderless panel that still takes keystrokes, so Escape closes it.
final class SummaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        StatusItemController.shared.close()
    }
}

/// The panel's content, with what the main window's views also read.
private struct MenuBarSummary: View {
    let model: AppModel
    @AppStorage("streamGraphs") private var streamGraphs = true

    var body: some View {
        MenuBarView()
            .environment(model)
            .environment(\.sampleInterval, model.updateSpeed.rawValue)
            .environment(\.streamsGraphs, streamGraphs)
    }
}
