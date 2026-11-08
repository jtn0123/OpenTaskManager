import AppKit
import OTMKit
import SwiftUI

/// A card's heading on an instrument panel (`RetroDisplay.isInstrument`): a
/// dot-matrix strip, its title lit and unlit cells running on to the
/// headline figure at the far end, on glass flooded with the card's colour
/// as its graph's panel is. Dark in either appearance, as the panels are.
struct InstrumentStrip: View {
    var title: String
    var tint: Color
    var font: NSFont
    var figure: Figure?

    /// The figure at the strip's end, counted to each reading.
    struct Figure {
        var value: Double
        var format: (Double) -> String
        /// The widest it gets, so the strip's cells don't shift as it changes.
        var widest: String
    }

    var body: some View {
        let height = GlyphCache.lineHeight(font)
        let metrics = RetroFigures.Metrics(font)
        HStack(spacing: 0) {
            InstrumentStripTitle(title: title.uppercased(), tint: tint, pitch: metrics.pitch, dot: metrics.dot,
                                 capHeight: metrics.capHeight, baseline: height + font.descender)
                .equatable()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            if let figure {
                AnimatedNumber(value: figure.value, format: figure.format, font: font, color: tint)
                    .frame(width: ceil(GlyphCache.width(of: figure.widest, font: font, look: GlyphCache.look)) + 1,
                           height: height, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            let shape = RoundedRectangle(cornerRadius: 5)
            ZStack {
                shape.fill(Color(nsColor: GraphColors.nsColor(RetroDisplay.instrumentGlass)))
                shape.fill(tint.opacity(RetroDisplay.instrumentFlood))
                shape.strokeBorder(tint.opacity(0.65), lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The strip's title and its unlit cells, drawn once per size.
private struct InstrumentStripTitle: View, Equatable {
    var title: String
    var tint: Color
    var pitch: CGFloat
    var dot: CGFloat
    var capHeight: CGFloat
    /// From the top.
    var baseline: CGFloat

    var body: some View {
        Canvas { context, size in
            // A cell is five dots and the one-dot gap after them.
            let cell = 6 * pitch
            let characters = Array(title)
            let cells = max(Int(size.width / cell), characters.count)
            var lit = Path(), glow = Path(), unlit = Path()
            for index in 0..<cells {
                let pattern = index < characters.count ? ReadoutGlyphs.titleDots(for: characters[index]) : nil
                for row in 0..<ReadoutGlyphs.rows {
                    let line = pattern.map { Array($0[row]) }
                    for column in 0..<5 {
                        let x = CGFloat(index) * cell + pitch / 2 + (CGFloat(column) + 0.5) * pitch
                        let y = baseline - capHeight + (CGFloat(row) + 0.5) * pitch
                        let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                        if line?[column] == "#" {
                            lit.addEllipse(in: rect)
                            // A halo a little past each lit dot, drawn as a
                            // wider dot rather than a blur.
                            glow.addEllipse(in: rect.insetBy(dx: -dot * 0.55, dy: -dot * 0.55))
                        } else {
                            unlit.addEllipse(in: rect)
                        }
                    }
                }
            }
            context.fill(unlit, with: .color(tint.opacity(RetroDisplay.unlitOpacity(dark: true))))
            context.fill(glow, with: .color(tint.opacity(0.22)))
            context.fill(lit, with: .color(tint))
        }
        .accessibilityElement()
        .accessibilityLabel(title.capitalized)
        .accessibilityAddTraits(.isHeader)
    }
}
