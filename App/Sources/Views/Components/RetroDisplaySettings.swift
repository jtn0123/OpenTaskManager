import AppKit
import OTMKit
import SwiftUI

/// Settings' retro display look: off, or live graphs on dark panels in one
/// colour with figures as lit dots or bars; its colour and glow; and a still
/// preview. Every change goes through `GraphColors`, which saves it and
/// redraws the graphs and figures at once.
struct RetroDisplaySettings: View {
    private let colors = GraphColors.shared

    var body: some View {
        let retro = colors.retro
        Section("Retro display") {
            Picker("Style", selection: binding(\.style)) {
                ForEach(RetroDisplay.Style.allCases) { Text($0.name).tag($0) }
            }
            Picker("Color", selection: binding(\.tint)) {
                ForEach(RetroDisplay.Tint.allCases) { tint in
                    Label { Text(tint.name) } icon: { Image(nsImage: Self.swatch(tint)) }
                        .tag(tint)
                }
            }
            Picker("Glow", selection: binding(\.glow)) {
                ForEach(RetroDisplay.Glow.allCases) { Text($0.name).tag($0) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(retro.isOn
                    ? "Live graphs are display panels, dark in either appearance, and figures are lit "
                        + (retro.style == .dotMatrix ? "dots. " : "bars. ")
                        + (retro.tint.isMulticolor ? "Each resource keeps its color from the palette above, made as vivid as it goes."
                            : "Graphs use the display's color in place of the palette; your own colors come back when it's off.")
                    : "Draws live graphs on dark display panels, each resource in its own vivid color or all in one, "
                        + "and figures as lit dots or bars. "
                        + "Off, graphs and figures look as usual.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // Off, the preview shows what Dot matrix would look like.
                RetroDisplayPreview(retro: retro.isOn ? retro : RetroDisplay(style: .dotMatrix, tint: retro.tint, glow: retro.glow))
                    .opacity(retro.isOn ? 1 : 0.55)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RetroDisplay, Value>) -> Binding<Value> {
        Binding {
            colors.retro[keyPath: keyPath]
        } set: { value in
            var retro = colors.retro
            retro[keyPath: keyPath] = value
            colors.setRetro(retro)
        }
    }

    /// A dot of the tint, for its menu item; not a template, so it keeps its colour.
    private static func swatch(_ tint: RetroDisplay.Tint) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = rect.insetBy(dx: 1.5, dy: 1.5)
            guard tint.isMulticolor else {
                GraphColors.nsColor(tint.tone).setFill()
                NSBezierPath(ovalIn: dot).fill()
                return true
            }
            // Color: the dot in quarters, a resource's colour each.
            let palette = GraphPalette.retro(.color)
            NSBezierPath(ovalIn: dot).addClip()
            for (index, role) in [GraphPalette.Role.cpu, .memory, .disk, .network].enumerated() {
                GraphColors.nsColor(palette[role].dark).setFill()
                let wedge = NSBezierPath()
                wedge.move(to: NSPoint(x: dot.midX, y: dot.midY))
                wedge.appendArc(withCenter: NSPoint(x: dot.midX, y: dot.midY), radius: dot.width,
                                startAngle: CGFloat(index) * 90, endAngle: CGFloat(index + 1) * 90)
                wedge.close()
                wedge.fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = tint.name
        return image
    }
}

/// The look as it draws, light mode beside dark: a figure as the cards show
/// it, then a still graph on the panel, whose lines are the palette's, solid,
/// filled and dashed. Drawn once per change, never ticking.
struct RetroDisplayPreview: View {
    let retro: RetroDisplay

    private static let font = NSFont.numeric(size: 26, weight: .semibold, rounded: true)

    var body: some View {
        HStack(spacing: 10) {
            panel(dark: false)
            panel(dark: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the retro display in light and dark mode")
    }

    private func panel(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dark ? "Dark" : "Light")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            readout(dark: dark)
                .frame(height: GlyphCache.lineHeight(Self.font) + 4, alignment: .leading)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: 64)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark ? Color(white: 0.118) : Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// "42.5 %" as a card's figure draws it in this appearance.
    @ViewBuilder private func readout(dark: Bool) -> some View {
        let color = GraphColors.nsColor(dark ? retro.readout.dark : retro.readout.light)
        let look = GlyphCache.Look(style: retro.style, glow: retro.glow, dark: dark)
        if let image = GlyphCache.image(of: "42.5 %", font: Self.font, color: color, scale: 2, look: look) {
            Image(decorative: image, scale: 2)
        }
    }

    /// The panel, its grid, and three lines over it with their bloom.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let palette = GraphPalette.retro(retro.tint, base: GraphColors.shared.basePalette)
        // Under Color the panel takes its first line's light, as a graph's does.
        let light = retro.tint.isMulticolor ? palette[.cpu].dark : retro.tint.tone
        let tint = Color(nsColor: GraphColors.nsColor(light))
        let shape = RoundedRectangle(cornerRadius: 6).path(in: CGRect(origin: .zero, size: size))
        context.fill(shape, with: .color(Color(nsColor: GraphColors.nsColor(RetroDisplay.panel(lit: light)))))
        let grid = Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            for fraction in stride(from: 0.125, to: 1, by: 0.125) {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            }
        }
        context.stroke(grid, with: .color(tint.opacity(RetroDisplay.gridOpacity)), lineWidth: 0.5)

        let solid = StrokeStyle(lineWidth: 1.75 * GraphEmphasis.traceWidth, lineCap: .round, lineJoin: .round)
        let lines = [
            GraphColorPreview.PreviewLine(role: .cpu, values: GraphColorPreview.wave(base: 0.32, swing: 0.16, phase: 0),
                                          style: solid, filled: true),
            GraphColorPreview.PreviewLine(role: .memory, values: GraphColorPreview.wave(base: 0.62, swing: 0.05, phase: 1.3),
                                          style: solid),
            GraphColorPreview.PreviewLine(role: .networkSecondary, values: GraphColorPreview.wave(base: 0.8, swing: 0.08, phase: 4.1),
                                          style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [4, 3])),
        ]
        for line in lines {
            let color = Color(nsColor: GraphColors.nsColor(palette[line.role].dark))
            let trace = GraphColorPreview.curve(line.values.map { size.height * (1 - $0) }, width: size.width)
            let style = line.style
            if line.filled {
                var area = trace
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                let fade = palette.emphasis.fill
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.45 * fade), color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            if retro.glow.bloom > 0 {
                var bloom = style
                bloom.lineWidth += 6
                context.stroke(trace, with: .color(color.opacity(retro.glow.bloom)), style: bloom)
            }
            context.stroke(trace, with: .color(color), style: style)
        }
        context.stroke(shape, with: .color(tint.opacity(RetroDisplay.edgeOpacity)), lineWidth: 1)
    }
}
