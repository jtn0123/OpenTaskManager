import AppKit
import OTMKit
import SwiftUI

/// Settings' graph colours: a preset, a still preview of it in both
/// appearances, a colour of the user's own for any resource, and Reset.
/// Every change goes through `GraphColors`, which saves it and redraws the
/// graphs at once.
struct GraphColorSettings: View {
    private let colors = GraphColors.shared
    @State private var showsResources = !GraphColors.shared.overrides.isEmpty

    var body: some View {
        Section("Graph colors") {
            Picker("Palette", selection: Binding(get: { colors.preset }, set: { colors.select($0) })) {
                ForEach(GraphPalette.Preset.allCases) { Text($0.name).tag($0) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(colors.preset.summary)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                GraphColorPreview(palette: colors.palette)
            }
            DisclosureGroup("Colors by resource", isExpanded: $showsResources) {
                ForEach(GraphPalette.Role.resources, id: \.self) { role in
                    ResourceColorRow(role: role)
                }
                Text("Light mode draws a color deeper where it needs to, and dark mode lighter, so lines and labels stay readable.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Reset Graph Colors") { colors.reset() }
                    .disabled(colors.preset == .standard && colors.overrides.isEmpty)
                    .help("Go back to the standard palette, with no colors of your own")
            }
        }
    }
}

/// A resource's colour well, and a button back to the preset's colour once
/// the user has picked one of their own.
private struct ResourceColorRow: View {
    typealias RGB = ColorContrast.RGB
    let role: GraphPalette.Role
    private let colors = GraphColors.shared

    var body: some View {
        let overridden = colors.overrides[role] != nil
        HStack(spacing: 6) {
            ColorPicker(selection: tone, supportsOpacity: false) {
                Text(role.title)
            }
            Button {
                colors.setOverride(nil, for: role)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Use the palette's color for \(role.title)")
            .accessibilityLabel("Use the palette's color for \(role.title)")
            .opacity(overridden ? 1 : 0)
            .disabled(!overridden)
        }
    }

    /// The tone the graphs start from: dark mode's colour.
    private var tone: Binding<Color> {
        Binding {
            Color(nsColor: GraphColors.nsColor(colors.palette[role].tone))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let picked = RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
            // Picking the palette's own colour again is no colour of the user's.
            let preset = GraphPalette.preset(colors.preset)[role].tone
            colors.setOverride(picked.hex == preset.hex ? nil : picked, for: role)
        }
    }
}

/// The palette as the graphs draw it, light mode beside dark: a still chart
/// whose lines are solid, dashed and dotted as on the History page, each
/// resource's swatch and the "by app" colours. Drawn once per palette,
/// never ticking.
struct GraphColorPreview: View {
    let palette: GraphPalette

    var body: some View {
        HStack(spacing: 10) {
            panel(dark: false)
            panel(dark: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the graph colors in light and dark mode")
    }

    /// One appearance's panel, its labels in that appearance's text colours.
    private func panel(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dark ? "Dark" : "Light")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            Canvas { context, size in
                draw(in: &context, size: size, dark: dark)
            }
            .frame(height: 64)
            swatches(dark: dark)
            seriesStrip(dark: dark)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark ? Color(white: 0.118) : Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func shade(_ swatch: GraphPalette.Swatch, dark: Bool) -> Color {
        Color(nsColor: GraphColors.nsColor(dark ? swatch.dark : swatch.light))
    }

    private struct PreviewLine {
        var role: GraphPalette.Role
        var values: [Double]
        var style: StrokeStyle
        var filled = false
    }

    private static let solid = StrokeStyle(lineWidth: 1.75 * GraphEmphasis.traceWidth, lineCap: .round, lineJoin: .round)
    private static let lines = [
        PreviewLine(role: .cpu, values: wave(base: 0.30, swing: 0.16, phase: 0), style: solid, filled: true),
        PreviewLine(role: .memory, values: wave(base: 0.62, swing: 0.05, phase: 1.3), style: solid),
        PreviewLine(role: .disk, values: wave(base: 0.45, swing: 0.12, phase: 2.6),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [4, 3])),
        PreviewLine(role: .network, values: wave(base: 0.78, swing: 0.09, phase: 4.1),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0, 3.6])),
    ]

    /// Four lines over the graphs' faint grid: CPU filled, memory solid,
    /// disk dashed and network dotted, weighed as the graphs weigh them
    /// (`GraphEmphasis`).
    private func draw(in context: inout GraphicsContext, size: CGSize, dark: Bool) {
        let emphasis = palette.emphasis
        let grid = Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
        }
        context.stroke(grid, with: .color((dark ? Color.white : .black).opacity((dark ? 0.065 : 0.11) * emphasis.grid)), lineWidth: 0.5)
        for line in Self.lines {
            let count = CGFloat(line.values.count - 1)
            let points = line.values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / count, y: size.height * (1 - value))
            }
            let trace = Path { $0.addLines(points) }
            if line.filled {
                var area = trace
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                // Washes keep the bright tone in both appearances, as on the graphs.
                let wash = shade(palette[line.role], dark: true)
                context.fill(area, with: .linearGradient(Gradient(colors: [wash.opacity(0.4 * emphasis.fill), wash.opacity(0.02 * emphasis.fill)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            let swatch = palette[line.role]
            let stroke = dark ? swatch.dark : emphasis.trace(swatch.light)
            context.stroke(trace, with: .color(Color(nsColor: GraphColors.nsColor(stroke))), style: line.style)
        }
    }

    /// A still, smooth-looking trace: 25 points between 0 and 1.
    private static func wave(base: Double, swing: Double, phase: Double) -> [Double] {
        (0..<25).map { index in
            let x = Double(index) / 4
            return min(max(base + swing * (sin(x + phase) * 0.7 + sin(2.3 * x + phase * 1.7) * 0.3), 0.04), 0.96)
        }
    }

    /// Each resource's swatch and name, three to a row.
    private func swatches(dark: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach([0, 3], id: \.self) { start in
                GridRow {
                    ForEach(GraphPalette.Role.resources[start..<start + 3], id: \.self) { role in
                        HStack(spacing: 4) {
                            Circle().fill(shade(palette[role], dark: dark)).frame(width: 7, height: 7)
                            Text(role.title).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func seriesStrip(dark: Bool) -> some View {
        HStack(spacing: 3) {
            Text("By app").font(.metadata).foregroundStyle(.secondaryText).padding(.trailing, 2)
            ForEach(palette.series.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(shade(palette.series[index], dark: dark))
                    .frame(width: 14, height: 8)
            }
        }
    }
}
