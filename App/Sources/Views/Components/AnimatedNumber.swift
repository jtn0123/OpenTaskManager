import AppKit
import OTMKit
import SwiftUI

/// A number that counts to each new value instead of jumping to it.
///
/// SwiftUI's own numeric transitions re-run layout for the whole window on
/// every frame. This view instead composes pre-rendered glyph bitmaps, and
/// only touches them while a change is in flight and the text differs. With
/// the retro display look on, those bitmaps are its dots or bars
/// (`RetroFigures`), in the display's colour unless the number has its own.
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
        view.configure(format: format, font: font, color: color.map(NSColor.init), centered: alignment == .center,
                       look: GlyphCache.look)
        view.set(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedNumberView, context: Context) -> CGSize? {
        CGSize(width: ceil(GlyphCache.width(of: format(value), font: font, look: GlyphCache.look)) + 1, height: GlyphCache.lineHeight(font))
    }
}

final class AnimatedNumberView: NSView, WindowAnimationClient {
    private static let duration: CFTimeInterval = 0.6
    private static let noAnimations: [String: any CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contentsScale": NSNull(),
    ]

    private var format: (Double) -> String = { String($0) }
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var color: NSColor?
    private var centered = false
    private var look: GlyphCache.Look?
    private var pieces: [CALayer] = []
    private var shown: Double?
    private var target = 0.0
    private var timing = GraphMotionTiming(start: 0, interval: AnimatedNumberView.duration)
    private var curve = GraphMotionCurve(GraphMotionSegment(start: 0, end: 0, startTangent: 0, endTangent: 0))
    private var renderedText = ""
    private var clock: WindowAnimationClock?
    var animationView: NSView? { self }

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

    func configure(format: @escaping (Double) -> String, font: NSFont, color: NSColor?, centered: Bool, look: GlyphCache.Look?) {
        self.format = format
        let restyle = font != self.font || color != self.color || centered != self.centered || look != self.look
        self.font = font
        self.color = color
        self.centered = centered
        self.look = look
        if restyle { draw(shown ?? target, force: true) }
    }

    func set(_ value: Double) {
        guard value.isFinite else { return }
        guard let current = shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopTicking()
            target = value
            shown = value
            draw(value, force: false)
            return
        }
        guard value != target else {
            // Same value, but the formatter may have changed (units, digits).
            if clock == nil { draw(value, force: false) }
            return
        }
        target = value
        // A change hidden by rounding or units needs no counting frames.
        if format(current) == format(value) {
            stopTicking()
            shown = value
            draw(value, force: false)
            return
        }
        timing = GraphMotionTiming(start: CACurrentMediaTime(), interval: Self.duration)
        curve = GraphMotionCurve(GraphMotionSegment(start: current, end: value, startTangent: 3 * (value - current), endTangent: 0))
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
        stopTicking()
        animationStopped()
    }

    private func startTicking() {
        if let next = WindowAnimationClock.start(self) {
            clock = next
        } else {
            stopTicking()
            animationStopped()
        }
    }

    private func stopTicking() {
        clock?.remove(self)
        clock = nil
    }

    func frameRate(displayRate: Double) -> Double { min(30, displayRate) }

    func animate(at time: CFTimeInterval) -> Bool {
        let progress = timing.progress(at: time)
        let value = progress == 1 ? target : curve.value(at: progress)
        shown = value
        draw(value, force: false)
        return progress < 1
    }

    func animationStopped() {
        clock = nil
        shown = target
        draw(target, force: false)
    }

    private func draw(_ value: Double, force: Bool) {
        let string = format(value)
        guard force || string != renderedText else { return }
        renderedText = string
        guard bounds.width > 0 else { return }

        var resolved = NSColor.labelColor
        let plain = look == nil ? NSColor.labelColor : GraphColors.shared.readoutColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: (color ?? plain).cgColor) ?? .labelColor
        }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let look = look.map { GlyphCache.Look(style: $0.style, glow: $0.glow, dark: isDark) }
        let scale = window?.backingScaleFactor ?? 2
        let glyphs = GlyphCache.pieces(of: string).compactMap {
            GlyphCache.glyph($0, font: font, color: resolved, scale: scale, look: look)
        }
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
            // A glowing figure's bitmap has room for the glow round it.
            piece.frame = CGRect(x: x - glyph.inset, y: y - glyph.inset, width: CGFloat(glyph.image.width) / scale,
                                 height: CGFloat(glyph.image.height) / scale)
            x += glyph.advance
        }
        setAccessibilityValue(string)
    }
}

/// Bitmaps of the characters animated numbers are built from, rendered once
/// per font, colour, scale and look. Digits and separators are cached one by
/// one; a unit suffix like " MB/s" is cached whole so its kerning survives.
@MainActor
enum GlyphCache {
    struct Glyph {
        let image: CGImage
        let advance: CGFloat
        /// Room left round the character for its glow, on every side.
        var inset: CGFloat = 0
    }

    /// The retro display look figures are drawn in; nil for type. `dark`
    /// is the window's appearance, which their glow and unlit parts follow.
    struct Look: Hashable {
        let style: RetroDisplay.Style
        let glow: RetroDisplay.Glow
        var dark = true
    }

    /// The look in use, from `GraphColors`.
    static var look: Look? {
        let retro = GraphColors.shared.retro
        return retro.isOn ? Look(style: retro.style, glow: retro.glow) : nil
    }

    private struct Key: Hashable {
        let text: String
        let font: NSFont
        let color: [CGFloat]
        let scale: CGFloat
        let look: Look?
    }

    private static var glyphs: [Key: Glyph] = [:]
    /// What's split off one character at a time: what a retro display draws.
    private static let numeric = ReadoutGlyphs.drawn

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

    private struct WidthKey: Hashable {
        let text: String
        let font: NSFont
        let look: Look?
    }

    private static var widths: [WidthKey: CGFloat] = [:]

    /// `text`'s width in `font`, typeset once. SwiftUI asks every number on a
    /// page for its size on each layout pass, and setting the text each time
    /// cost about 3% of a core on Overview.
    static func width(of text: String, font: NSFont, look: Look?) -> CGFloat {
        let key = WidthKey(text: text, font: font, look: look)
        if let width = widths[key] { return width }
        // Figures come and go; a cap keeps the cache to recent ones.
        if widths.count >= 4_096 { widths.removeAll(keepingCapacity: true) }
        let width = if let look {
            pieces(of: text).reduce(0) { $0 + RetroFigures.advance(of: $1, font: font, style: look.style) }
        } else {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        widths[key] = width
        return width
    }

    static func glyph(_ text: String, font: NSFont, color: NSColor, scale: CGFloat, look: Look?) -> Glyph? {
        let rgba = color.usingColorSpace(.sRGB)
        let components = [rgba?.redComponent ?? 1, rgba?.greenComponent ?? 1, rgba?.blueComponent ?? 1, rgba?.alphaComponent ?? 1]
        let key = Key(text: text, font: font, color: components, scale: scale, look: look)
        if let cached = glyphs[key] { return cached }
        // Values and units vary, but not without bound; start over rather than grow forever.
        if glyphs.count > 2_000 { glyphs.removeAll() }
        if let look {
            let glyph = retroGlyph(text, font: font, color: rgba ?? color, scale: scale, look: look)
            glyphs[key] = glyph
            return glyph
        }

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

    /// `text` laid out as `AnimatedNumberView` lays out its pieces, in one
    /// bitmap: for a still preview.
    static func image(of text: String, font: NSFont, color: NSColor, scale: CGFloat, look: Look?) -> CGImage? {
        let glyphs = pieces(of: text).compactMap { glyph($0, font: font, color: color, scale: scale, look: look) }
        let inset = glyphs.map(\.inset).max() ?? 0
        let advance = glyphs.reduce(0) { $0 + $1.advance }
        let width = Int(ceil((advance + 1 + 2 * inset) * scale))
        let height = Int(ceil((lineHeight(font) + 2 * inset) * scale))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var x = inset
        for glyph in glyphs {
            context.draw(glyph.image, in: CGRect(x: (x - glyph.inset) * scale, y: (inset - glyph.inset) * scale,
                                                 width: CGFloat(glyph.image.width), height: CGFloat(glyph.image.height)))
            x += glyph.advance
        }
        return context.makeImage()
    }

    /// A character, or a unit, as a retro display draws it, with room round
    /// it for its glow.
    private static func retroGlyph(_ text: String, font: NSFont, color: NSColor, scale: CGFloat, look: Look) -> Glyph? {
        let advance = RetroFigures.advance(of: text, font: font, style: look.style)
        // Lit figures glow on a dark window; on a pale one a glow only blurs them.
        let blur = look.dark ? look.glow.readoutBlur * RetroFigures.cell(font: font, style: look.style) : 0
        let inset = blur > 0 ? ceil(blur * 1.5) + 1 : 0
        let width = Int(ceil((advance + 1 + 2 * inset) * scale))
        let height = Int(ceil((lineHeight(font) + 2 * inset) * scale))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: inset, y: inset)
        let ink = RetroFigures.Ink(font: font, style: look.style, color: color, unlit: RetroDisplay.unlitOpacity(dark: look.dark),
                                   blur: blur, scale: scale)
        RetroFigures.draw(text, in: context, with: ink)
        guard let image = context.makeImage() else { return nil }
        return Glyph(image: image, advance: advance, inset: inset)
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
