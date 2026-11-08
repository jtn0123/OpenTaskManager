import AppKit
import OTMKit

/// Draws a retro display's figures (`RetroDisplay.Style`) for `GlyphCache`:
/// each character `ReadoutGlyphs` knows as lit dots or bars over faint unlit
/// ones, as tall as the font's capitals so they sit where its figures would,
/// and a unit beside them in monospaced type. Drawn once into a glyph's
/// cached bitmap, glow and all, so a counting number costs what it did.
enum RetroFigures {
    /// The sizes one font's figures are drawn at.
    struct Metrics {
        let capHeight: CGFloat

        init(_ font: NSFont) {
            capHeight = max(font.capHeight, 4)
        }

        /// Dot matrix: from one dot's centre to the next.
        var pitch: CGFloat { capHeight / CGFloat(ReadoutGlyphs.rows) }
        /// A dot's width, the rest of its pitch dark between dots.
        var dot: CGFloat { pitch * 0.86 }
        /// Segments: a bar's thickness, a figure's width and the room each side.
        var bar: CGFloat { max(capHeight * 0.15, 1) }
        var figureWidth: CGFloat { capHeight * 0.6 }
        var margin: CGFloat { capHeight * 0.14 }
        /// How far a segment figure leans right, per point of height.
        static let lean: CGFloat = 0.07
    }

    /// A unit's type: monospaced, smaller than the figures as a panel's
    /// legend is, but never under the 12 points a reading needs.
    static func unitFont(for font: NSFont) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(font.pointSize * 0.62, min(font.pointSize, 12)), weight: .semibold)
    }

    /// The character drawn as dots or bars, or nil for type.
    private static func drawn(_ piece: String) -> Character? {
        guard piece.count == 1, let character = piece.first, ReadoutGlyphs.drawn.contains(character) else { return nil }
        return character
    }

    /// How far `piece` moves the pen.
    static func advance(of piece: String, font: NSFont, style: RetroDisplay.Style) -> CGFloat {
        guard let character = drawn(piece) else {
            return (piece as NSString).size(withAttributes: [.font: unitFont(for: font)]).width
        }
        let metrics = Metrics(font)
        if style == .dotMatrix {
            return CGFloat((ReadoutGlyphs.dotColumns(for: character) ?? 5) + 1) * metrics.pitch
        }
        if case .point = ReadoutGlyphs.segmentForm(for: character) {
            return metrics.bar * 1.2 + 2 * metrics.margin
        }
        return metrics.figureWidth + Metrics.lean * metrics.capHeight + 2 * metrics.margin
    }

    /// What a glow's blur is measured in: a dot's pitch, or a bar's thickness.
    static func cell(font: NSFont, style: RetroDisplay.Style) -> CGFloat {
        let metrics = Metrics(font)
        return style == .dotMatrix ? metrics.pitch : metrics.bar
    }

    /// How a piece is drawn: its font and style, lit in `color`, unlit
    /// parts at `unlit` of its opacity, the lit parts blurred `blur` points
    /// round, at `scale` pixels a point.
    struct Ink {
        let font: NSFont
        let style: RetroDisplay.Style
        let color: NSColor
        let unlit: Double
        let blur: CGFloat
        let scale: CGFloat
    }

    /// Draws `piece` from x = 0, its line box's foot at y = 0, as type is.
    static func draw(_ piece: String, in context: CGContext, with ink: Ink) {
        let font = ink.font, color = ink.color
        let baseline = -font.descender
        let glow = { (context: CGContext) in
            guard ink.blur > 0 else { return }
            // A shadow's blur is in device pixels, whatever the scale.
            context.setShadow(offset: .zero, blur: ink.blur * ink.scale, color: color.withAlphaComponent(0.85).cgColor)
        }
        guard let character = drawn(piece) else {
            let unit = unitFont(for: font)
            context.saveGState()
            glow(context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            // The point is the bottom of the unit's line box; its baseline meets the figures'.
            NSAttributedString(string: piece, attributes: [.font: unit, .foregroundColor: color])
                .draw(at: CGPoint(x: 0, y: baseline + unit.descender))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            return
        }
        let shapes = ink.style == .dotMatrix ? dots(character, font: font, baseline: baseline)
            : segments(character, font: font, baseline: baseline)
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(color.alphaComponent * ink.unlit).cgColor)
        context.addPath(shapes.unlit)
        context.fillPath()
        glow(context)
        context.setFillColor(color.cgColor)
        context.addPath(shapes.lit)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Dot matrix

    private static func dots(_ character: Character, font: NSFont, baseline: CGFloat) -> (lit: CGPath, unlit: CGPath) {
        let metrics = Metrics(font)
        let pitch = metrics.pitch, size = metrics.dot
        let lit = CGMutablePath(), unlit = CGMutablePath()
        let columns = ReadoutGlyphs.dotColumns(for: character) ?? 0
        for row in 0..<ReadoutGlyphs.rows {
            for column in 0..<columns {
                // Half a pitch of room each side of the character.
                let x = pitch / 2 + (CGFloat(column) + 0.5) * pitch
                let y = baseline + metrics.capHeight - (CGFloat(row) + 0.5) * pitch
                let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                (ReadoutGlyphs.isLit(character, row: row, column: column) ? lit : unlit).addEllipse(in: rect)
            }
        }
        return (lit, unlit)
    }

    // MARK: Segments

    private static func segments(_ character: Character, font: NSFont, baseline: CGFloat) -> (lit: CGPath, unlit: CGPath) {
        let metrics = Metrics(font)
        let lit = CGMutablePath(), unlit = CGMutablePath()
        let bar = metrics.bar, half = bar / 2, width = metrics.figureWidth, height = metrics.capHeight
        let left = metrics.margin + half, right = metrics.margin + width - half
        let bottom = baseline + half, top = baseline + height - half, middle = baseline + height / 2
        switch ReadoutGlyphs.segmentForm(for: character) {
        case .figure(let litBars):
            // Each bar's two ends.
            let bars: [ReadoutGlyphs.Segments: [CGPoint]] = [
                .top: [CGPoint(x: left, y: top), CGPoint(x: right, y: top)],
                .upperRight: [CGPoint(x: right, y: top), CGPoint(x: right, y: middle)],
                .lowerRight: [CGPoint(x: right, y: middle), CGPoint(x: right, y: bottom)],
                .bottom: [CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)],
                .lowerLeft: [CGPoint(x: left, y: middle), CGPoint(x: left, y: bottom)],
                .upperLeft: [CGPoint(x: left, y: top), CGPoint(x: left, y: middle)],
                .middle: [CGPoint(x: left, y: middle), CGPoint(x: right, y: middle)],
            ]
            for (segment, ends) in bars {
                addBar(from: ends[0], to: ends[1], thickness: bar, to: litBars.contains(segment) ? lit : unlit)
            }
        case .point(let comma):
            let side = bar * 1.2
            lit.addRect(CGRect(x: metrics.margin, y: baseline, width: side, height: side))
            if comma {
                // A short tail down and back from the point, into the descender.
                lit.addLines(between: [CGPoint(x: metrics.margin + side, y: baseline),
                                       CGPoint(x: metrics.margin + side * 0.45, y: baseline - side * 1.3),
                                       CGPoint(x: metrics.margin, y: baseline - side * 1.3),
                                       CGPoint(x: metrics.margin + side * 0.4, y: baseline)])
                lit.closeSubpath()
            }
        case .plus:
            let reach = (right - left) / 2
            let centre = (left + right) / 2
            addBar(from: CGPoint(x: left, y: middle), to: CGPoint(x: right, y: middle), thickness: bar, to: lit)
            addBar(from: CGPoint(x: centre, y: middle + reach), to: CGPoint(x: centre, y: middle - reach), thickness: bar, to: lit)
        case .percent:
            let box = width * 0.38
            let line = bar * 0.75
            for origin in [CGPoint(x: metrics.margin, y: baseline + height - box), CGPoint(x: metrics.margin + width - box, y: baseline)] {
                let rect = CGRect(origin: origin, size: CGSize(width: box, height: box)).insetBy(dx: line / 2, dy: line / 2)
                lit.addPath(CGPath(rect: rect, transform: nil).copy(strokingWithWidth: line, lineCap: .butt, lineJoin: .miter,
                                                                   miterLimit: 10))
            }
            addBar(from: CGPoint(x: left, y: bottom), to: CGPoint(x: right, y: top), thickness: bar * 0.85, to: lit)
        case nil:
            break
        }
        // Lean the figure as segment displays do, pivoting at the baseline.
        var lean = CGAffineTransform(a: 1, b: 0, c: Metrics.lean, d: 1, tx: -Metrics.lean * baseline, ty: 0)
        return (lit.copy(using: &lean) ?? lit, unlit.copy(using: &lean) ?? unlit)
    }

    /// A bar from `start` to `end` with pointed ends, short of both by a
    /// little so the bars of a figure stay apart. The points are short, so
    /// a small figure's bars stay mostly solid and don't read as dashes;
    /// two bars meeting at a corner still clear each other.
    private static func addBar(from start: CGPoint, to end: CGPoint, thickness: CGFloat, to path: CGMutablePath) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > thickness else { return }
        let along = CGPoint(x: dx / length, y: dy / length)
        let across = CGPoint(x: -along.y, y: along.x)
        let gap = thickness * 0.2, tip = thickness * 0.35, half = thickness / 2
        func point(_ from: CGPoint, _ forward: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: from.x + along.x * forward + across.x * side, y: from.y + along.y * forward + across.y * side)
        }
        path.addLines(between: [
            point(start, gap, 0), point(start, gap + tip, half), point(end, -gap - tip, half),
            point(end, -gap, 0), point(end, -gap - tip, -half), point(start, gap + tip, -half),
        ])
        path.closeSubpath()
    }
}
