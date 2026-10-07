import AppKit
import Carbon.HIToolbox
import OTMKit
import SwiftUI

/// Caches file icons by path. `NSWorkspace.icon(forFile:)` hits the disk, and
/// the process list asks for hundreds of icons every refresh.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    /// For bare executables, and processes not in the latest snapshot yet.
    static let generic: NSImage = {
        let image = NSWorkspace.shared.icon(for: .unixExecutable)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    static func icon(for process: ProcessSample, app: NSRunningApplication?) -> NSImage {
        // `NSRunningApplication.icon` makes a new image on every call, and a
        // new image redraws the row's icon from full size every refresh.
        if let app, let bundle = app.bundleURL?.path {
            if let cached = icons[bundle] { return cached }
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                icons[bundle] = icon
                return icon
            }
        }
        if let icon = app?.icon { return icon }
        guard let path = process.bundlePath ?? process.executablePath else { return generic }
        if let cached = icons[path] { return cached }
        // Only bundles have meaningful icons; bare executables all look alike.
        let image = process.bundlePath != nil ? NSWorkspace.shared.icon(forFile: path) : generic
        image.size = NSSize(width: 16, height: 16)
        icons[path] = image
        return image
    }

    /// An app bundle's icon, or the generic executable icon without one.
    static func icon(forBundle path: String?) -> NSImage {
        guard let path else { return generic }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        icons[path] = image
        return image
    }
}

/// The menu bar item: a bar graph of recent CPU load beside the current
/// figure, drawn as a template so it follows the menu bar's appearance.
@MainActor
enum MenuBarIcon {
    private static let bars = 14
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 1
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    static func image(history: [Double], usage: Double) -> NSImage {
        let height: CGFloat = 16
        let graphWidth = CGFloat(bars) * (barWidth + gap) - gap
        let text = Format.percent(usage) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // Reserve room for "99%" so the item doesn't jiggle as the number changes.
        let textWidth = ceil(max(text.size(withAttributes: attributes).width, ("99%" as NSString).size(withAttributes: attributes).width))
        let size = NSSize(width: graphWidth + 4 + textWidth, height: height)
        let values = Array(history.suffix(bars))

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSRect(x: 0, y: 1, width: graphWidth, height: 1).fill()
            NSColor.black.setFill()
            for (index, value) in values.enumerated() {
                let x = CGFloat(bars - values.count + index) * (barWidth + gap)
                let barHeight = max(1, CGFloat(min(max(value, 0), 1)) * (height - 2))
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barWidth, height: barHeight), xRadius: 0.5, yRadius: 0.5).fill()
            }
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: size.width - textSize.width, y: (height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Lets AppKit code (the global hot key, the Dock menu) open SwiftUI windows.
@MainActor
enum WindowOpener {
    static var openMainWindow: (() -> Void)?

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// System-wide hot key via Carbon's RegisterEventHotKey, which (unlike an
/// NSEvent monitor) needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handler)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4F_54_4D_31), id: 1) // "OTM1"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateHotKey()
        HistoryRecordingStore.shared.handleLaunchArguments()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHotKey() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowOpener.showMainWindow() }
        return true
    }

    /// A recording file double-clicked in the Finder, or dropped on the
    /// app's icon, opens on the History page.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == RecordingFile.fileExtension }) else { return }
        HistoryRecordingStore.shared.open(url)
        WindowOpener.showMainWindow()
    }

    /// ⌃⇧⎋, the shortcut Windows users already have in their fingers.
    private func updateHotKey() {
        let enabled = UserDefaults.standard.object(forKey: "globalHotKeyEnabled") as? Bool ?? true
        if enabled, hotKey == nil {
            hotKey = GlobalHotKey(keyCode: kVK_Escape, modifiers: controlKey | shiftKey) {
                WindowOpener.showMainWindow()
            }
        } else if !enabled, let current = hotKey {
            current.unregister()
            hotKey = nil
        }
    }
}
