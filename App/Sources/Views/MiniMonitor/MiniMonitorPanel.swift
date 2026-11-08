import AppKit
import OTMKit

/// The mini monitor's window: borderless, never key and never activating the
/// app, on every Space and over full-screen apps. Dragging it anywhere moves
/// it, a double-click opens the main window and a Control-click or right-click
/// opens its menu; the controller handles the last two.
final class MiniMonitorPanel: NSPanel {
    var doubleClicked: (() -> Void)?
    var menuRequested: ((NSEvent) -> Void)?
    /// Whether a click brings it in front of the windows it's among (`MiniMonitorLevel.amongWindows`).
    var raisesOnClick = false

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: content.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ level: MiniMonitorLevel) {
        switch level {
        case .aboveWindows: self.level = .floating
        case .amongWindows: self.level = .normal
        // Just under every window: over the desktop's icons, and its widgets,
        // which sit a level over the icons and would cover it there.
        case .desktop: self.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        }
        raisesOnClick = level == .amongWindows
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control), .rightMouseDown:
            menuRequested?(event)
        case .leftMouseDown where event.clickCount == 2:
            doubleClicked?()
        case .leftMouseDown:
            if raisesOnClick { orderFrontRegardless() }
            performDrag(with: event)
        default:
            super.sendEvent(event)
        }
    }
}

/// The panel's content: a translucent rounded backing behind the SwiftUI
/// view, fading to the chosen opacity when the pointer isn't over it.
final class MiniMonitorBacking: NSVisualEffectView {
    static let cornerRadius: CGFloat = 10

    /// The panel's opacity away from the pointer, and whether it turns opaque under it.
    var restingOpacity: CGFloat = 1 { didSet { updateOpacity() } }
    var solidUnderPointer = true { didSet { updateOpacity() } }
    private var pointerInside = false

    init(content: NSView) {
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.mask(radius: Self.cornerRadius)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateOpacity()
    }

    private func updateOpacity() {
        window?.alphaValue = pointerInside && solidUnderPointer ? 1 : restingOpacity
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateOpacity()
    }

    /// A stretchable rounded rectangle, its corners kept by the cap insets.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSScreen {
    /// The display's UUID, which lasts across restarts and reconnections, unlike its number.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
