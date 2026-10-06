import AppKit
import SwiftUI

/// A number that counts to each new value instead of jumping to it.
///
/// SwiftUI's own numeric transitions re-run layout for the whole window on
/// every frame. This view instead composes pre-rendered glyph bitmaps, and
/// only touches them while a change is in flight and the text differs.
struct AnimatedNumber: NSViewRepresentable {
    var value: Double
    var format: (Double) -> String
    var font: NSFont
    var color: Color?
    var alignment: Alignment = .leading

    enum Alignment {
        case leading, center
    }

    func makeNSView(context: Context) -> AnimatedNumberView {
        AnimatedNumberView()
    }

    func updateNSView(_ view: AnimatedNumberView, context: Context) {
        view.configure(format: format, font: font, color: color.map(NSColor.init), centered: alignment == .center)
        view.set(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedNumberView, context: Context) -> CGSize? {
        let measured = (format(value) as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width) + 1, height: GlyphCache.lineHeight(font))
    }
}

final class AnimatedNumberView: NSView {
    private static let duration: CFTimeInterval = 0.6
    private static let noAnimations: [String: any CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contentsScale": NSNull(),
    ]

    private var format: (Double) -> String = { String($0) }
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var color: NSColor?
    private var centered = false
    private var pieces: [CALayer] = []
    private var shown: Double?
    private var from = 0.0
    private var target = 0.0
    private var start: CFTimeInterval = 0
    private var renderedText = ""
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(format: @escaping (Double) -> String, font: NSFont, color: NSColor?, centered: Bool) {
        self.format = format
        let restyle = font != self.font || color != self.color || centered != self.centered
        self.font = font
        self.color = color
        self.centered = centered
        if restyle { draw(shown ?? target, force: true) }
    }

    func set(_ value: Double) {
        guard value.isFinite else { return }
        guard let current = shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            target = value
            shown = value
            draw(value, force: false)
            return
        }
        guard value != target else {
            // Same value, but the formatter may have changed (units, digits).
            if link == nil { draw(value, force: false) }
            return
        }
        from = current
        target = value
        start = CACurrentMediaTime()
        startTicking()
    }

    override func layout() {
        super.layout()
        draw(shown ?? target, force: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw(shown ?? target, force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw(shown ?? target, force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() }
    }

    private func startTicking() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        // Thirty changes a second reads as fluid counting, at half the cost of 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let progress = min((CACurrentMediaTime() - start) / Self.duration, 1)
        let eased = 1 - pow(1 - progress, 3)
        let value = from + (target - from) * eased
        shown = value
        draw(value, force: false)
        if progress >= 1 { stopTicking() }
    }

    private func draw(_ value: Double, force: Bool) {
        let string = format(value)
        guard force || string != renderedText else { return }
        renderedText = string
        guard bounds.width > 0 else { return }

        var resolved = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: (color ?? .labelColor).cgColor) ?? .labelColor
        }
        let scale = window?.backingScaleFactor ?? 2
        let glyphs = GlyphCache.pieces(of: string).compactMap { GlyphCache.glyph($0, font: font, color: resolved, scale: scale) }
        let total = glyphs.reduce(0) { $0 + $1.advance }
        let height = GlyphCache.lineHeight(font)
        var x = centered ? (bounds.width - total) / 2 : 0
        let y = (bounds.height - height) / 2

        // No explicit transaction: every number that changes this frame then
        // lands in the run loop's single implicit commit.
        while pieces.count < glyphs.count {
            let piece = CALayer()
            piece.contentsGravity = .bottomLeft
            piece.actions = Self.noAnimations
            layer?.addSublayer(piece)
            pieces.append(piece)
        }
        for (index, piece) in pieces.enumerated() {
            guard index < glyphs.count else {
                piece.isHidden = true
                continue
            }
            let glyph = glyphs[index]
            piece.isHidden = false
            piece.contents = glyph.image
            piece.contentsScale = scale
            piece.frame = CGRect(x: x, y: y, width: CGFloat(glyph.image.width) / scale, height: height)
            x += glyph.advance
        }
        setAccessibilityValue(string)
    }
}

/// Bitmaps of the characters animated numbers are built from, rendered once
/// per font, colour and scale. Digits and separators are cached one by one;
/// a unit suffix like " MB/s" is cached whole so its kerning survives.
@MainActor
enum GlyphCache {
    struct Glyph {
        let image: CGImage
        let advance: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let font: NSFont
        let color: [CGFloat]
        let scale: CGFloat
    }

    private static var glyphs: [Key: Glyph] = [:]
    private static let numeric = Set("0123456789.,-+−%")

    /// Splits "312.5 MB/s" into "3", "1", "2", ".", "5" and " MB/s".
    static func pieces(of string: String) -> [String] {
        var result: [String] = []
        var index = string.startIndex
        while index < string.endIndex, numeric.contains(string[index]) {
            result.append(String(string[index]))
            index = string.index(after: index)
        }
        if index < string.endIndex { result.append(String(string[index...])) }
        return result
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    static func glyph(_ text: String, font: NSFont, color: NSColor, scale: CGFloat) -> Glyph? {
        let rgba = color.usingColorSpace(.sRGB)
        let components = [rgba?.redComponent ?? 1, rgba?.greenComponent ?? 1, rgba?.blueComponent ?? 1, rgba?.alphaComponent ?? 1]
        let key = Key(text: text, font: font, color: components, scale: scale)
        if let cached = glyphs[key] { return cached }
        // Values and units vary, but not without bound; start over rather than grow forever.
        if glyphs.count > 2_000 { glyphs.removeAll() }

        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let advance = string.size().width
        let height = lineHeight(font)
        let width = Int(ceil((advance + 1) * scale))
        guard width > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: Int(ceil(height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // The point is the bottom of the line box, not the baseline.
        string.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let glyph = Glyph(image: image, advance: advance)
        glyphs[key] = glyph
        return glyph
    }
}

extension NSFont {
    /// System font with digits of equal width, optionally in the rounded design.
    static func numeric(size: CGFloat, weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
