import AppKit
import OTMKit

/// No timer and no window demand: fed by the existing system sampling path.
@MainActor
final class DockIconController {
    private let defaults: UserDefaults
    private let render: @MainActor (DockGraphDrawing?) -> Void
    private var feed = DockGraphFeed()
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, paused: Bool = false,
         render: @escaping @MainActor (DockGraphDrawing?) -> Void = DockIconRenderer.present) {
        self.defaults = defaults
        self.render = render
        feed.setPaused(paused)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    private func sync() {
        guard feed.setMode(Settings.dockGraphMode.get(in: defaults)) else { return }
        if feed.mode == .off {
            render(nil)
        } else if let drawing = feed.drawing(at: ProcessInfo.processInfo.systemUptime) {
            render(drawing)
        }
    }

    func setPaused(_ paused: Bool) {
        feed.setPaused(paused)
        if let drawing = feed.drawing(at: ProcessInfo.processInfo.systemUptime) { render(drawing) }
    }

    func update(cpu: Double, memory: Double, at time: TimeInterval, visible: Bool) {
        feed.add(cpu: cpu, memory: memory, at: time)
        if let drawing = feed.drawing(at: time, visible: visible) { render(drawing) }
    }
}

/// A cached bitmap in the Dock tile, leaving the app's normal icon intact
/// in the app switcher. Off removes this content view and restores the icon.
@MainActor
enum DockIconRenderer {
    private static var view: NSImageView?
    private static var previous: DockGraphDrawing?
    private static var cached: NSImage?

    static func present(_ drawing: DockGraphDrawing?) {
        let tile = NSApp.dockTile
        guard let drawing else {
            tile.contentView = nil
            view = nil
            previous = nil
            cached = nil
            tile.display()
            return
        }
        let imageView = view ?? NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image(drawing)
        imageView.setAccessibilityLabel("\(drawing.mode.title), \(drawing.percent.map { "\($0)%" } ?? "collecting")"
                                        + (drawing.paused ? ", metrics paused" : ""))
        if view == nil { tile.contentView = imageView; view = imageView }
        tile.display()
    }

    static func image(_ drawing: DockGraphDrawing) -> NSImage {
        if drawing == previous, let cached { return cached }
        let size = NSSize(width: 128, height: 128)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        paint(drawing)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        bitmap.size = size
        image.addRepresentation(bitmap)
        previous = drawing
        cached = image
        return image
    }

    private static func paint(_ drawing: DockGraphDrawing) {
        let face = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 120, height: 120), xRadius: 23, yRadius: 23)
        NSColor(srgbRed: 0.06, green: 0.09, blue: 0.13, alpha: 1).setFill()
        face.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        face.lineWidth = 1
        face.stroke()
        let tint = drawing.mode == .cpu ? NSColor.systemGreen : NSColor.systemPurple
        text(drawing.mode == .cpu ? "CPU" : "MEMORY", y: 101, size: 12, color: tint)
        text(drawing.percent.map { "\($0)%" } ?? "—", y: 68, size: 29, color: .white)
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: 14, y: 28, width: 100, height: 1).fill()
        tint.setFill()
        let pitch = 100.0 / Double(DockGraphFeed.points)
        for (index, height) in drawing.heights.enumerated() {
            guard let height else { continue }
            let x = 14 + Double(DockGraphFeed.points - drawing.heights.count + index) * pitch
            NSRect(x: x, y: 29, width: pitch - 0.35, height: max(Double(height), 0.5)).fill()
        }
        text(drawing.paused ? "PAUSED" : "OTM · 2 MIN", y: 12, size: 8,
             color: drawing.paused ? .systemOrange : .white.withAlphaComponent(0.75))
    }

    private static func text(_ text: String, y: Double, size: Double, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        ]
        let value = text as NSString
        value.draw(at: NSPoint(x: (128 - value.size(withAttributes: attributes).width) / 2, y: y), withAttributes: attributes)
    }
}
