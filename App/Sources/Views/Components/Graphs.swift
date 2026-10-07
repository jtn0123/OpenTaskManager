import OTMKit
import SwiftUI

/// The data colours. Each is a bright tone that glows on dark cards and, in
/// light mode, a deeper shade of the same hue for lines and text. Fills and
/// washes take `fillShade`, which stays pastel. The graph colours come from
/// the palette picked in Settings (`GraphColors`, presets in OTMKit's
/// `GraphPalette`): reading one in a view's body observes it, so the view
/// redraws when the palette changes. `data(_:)` makes the fixed colours of
/// other pages the same way.
enum Theme {
    static var cpu: Color { color(.cpu) }
    static var memory: Color { color(.memory) }
    static var disk: Color { color(.disk) }
    static var diskSecondary: Color { color(.diskSecondary) }
    static var network: Color { color(.network) }
    static var networkSecondary: Color { color(.networkSecondary) }
    static var gpu: Color { color(.gpu) }
    static var power: Color { color(.power) }
    static var thermal: Color { color(.thermal) }
    static var fan: Color { color(.fan) }

    // Memory composition and paging.
    static var wired: Color { color(.wired) }
    static var compressed: Color { color(.compressed) }
    static var cached: Color { color(.cached) }
    static var swap: Color { color(.swap) }
    static var pageIn: Color { color(.pageIn) }
    static var pageOut: Color { color(.pageOut) }

    // Power components and supply.
    static var neuralEngine: Color { color(.neuralEngine) }
    static var dram: Color { color(.dram) }
    static var restOfSystem: Color { color(.restOfSystem) }
    static var charging: Color { color(.charging) }
    static var discharging: Color { color(.discharging) }

    // GPU engines and clock.
    static var gpuRenderer: Color { color(.gpuRenderer) }
    static var gpuTiler: Color { color(.gpuTiler) }
    static var gpuClock: Color { color(.gpuClock) }

    /// Everything not broken out on its own.
    static var other: Color { color(.other) }

    static func color(_ role: GraphPalette.Role) -> Color {
        GraphColors.shared.color(role)
    }

    /// The `index`th colour for series without an app of their own (core
    /// clusters, users), round the palette's.
    static func series(_ index: Int) -> Color {
        GraphColors.shared.seriesColor(index)
    }

    /// Colour for a core tier: the fastest tier (level 0) gets the CPU's.
    static func tier(_ level: Int) -> Color {
        level == 0 ? cpu : color(.slowerTier)
    }

    /// Colour for each kind of temperature sensor.
    static func sensor(_ kind: SensorKind) -> Color {
        switch kind {
        case .chip: thermal
        case .storage: color(.storageSensor)
        case .battery: color(.batterySensor)
        }
    }

    static func pressure(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .green
    }

    /// Contrast the light-mode shades reach against white: WCAG AA for text,
    /// since the same colours draw headings, legends and state labels.
    static let lightContrast = 4.5

    /// A data colour: this sRGB tone in dark mode, and the same hue deepened
    /// to `lightContrast` in light mode.
    static func data(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        data(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }

    /// A data colour from a system colour: unchanged in dark mode, deepened
    /// in light mode, where the system tints are too pale for text.
    static func data(_ base: NSColor) -> Color {
        var tone = ColorContrast.RGB(red: 0, green: 0, blue: 0)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let srgb = base.usingColorSpace(.sRGB) {
                tone = ColorContrast.RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
            }
        }
        let deep = ColorContrast.deepened(tone, toContrast: lightContrast)
        let light = NSColor(srgbRed: deep.red, green: deep.green, blue: deep.blue, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? base : light
        })
    }

    /// Colour for each kind of disk space on the Storage page. Mid-tones, so
    /// white labels read on every one of them in light and dark mode.
    static func category(_ category: DiskCategory) -> Color {
        switch category {
        case .apps: Color(red: 0.25, green: 0.53, blue: 0.98)
        case .developer: Color(red: 0.58, green: 0.40, blue: 0.94)
        case .media: Color(red: 0.91, green: 0.33, blue: 0.56)
        case .audio: Color(red: 0.95, green: 0.52, blue: 0.18)
        case .documents: Color(red: 0.13, green: 0.66, blue: 0.50)
        case .archives: Color(red: 0.80, green: 0.62, blue: 0.10)
        case .caches: Color(red: 0.18, green: 0.65, blue: 0.82)
        case .system: Color(red: 0.47, green: 0.51, blue: 0.64)
        case .other: Color(red: 0.55, green: 0.52, blue: 0.49)
        }
    }

    /// The "smaller items" rest of a folder on the Storage page.
    static let smallerItems = Color(white: 0.48)

    // MARK: Text

    /// Secondary text: labels, captions, units and other metadata. Stronger
    /// than the system's secondary label colour, which washes out on the
    /// tinted cards (see `TextTone`). Pair it with `Font.metadata` or larger.
    static let secondaryText = TextStyle(level: .secondary)
    /// Placeholders such as "—" and other text meant to recede, still legible.
    static let tertiaryText = TextStyle(level: .tertiary)
}

/// A text colour from `TextTone` for the current appearance. On a selected
/// table row, where the system's own styles turn white over the accent
/// colour, it gives way to the system's hierarchical style; with Increase
/// Contrast on it draws stronger still.
struct TextStyle: ShapeStyle {
    var level: TextTone.Level

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if environment.backgroundProminence == .increased {
            return AnyShapeStyle(level == .secondary ? HierarchicalShapeStyle.secondary : .tertiary)
        }
        let dark = environment.colorScheme == .dark
        let boost = environment.colorSchemeContrast == .increased ? 0.15 : 0
        return AnyShapeStyle(Color(white: dark ? 1 : 0, opacity: TextTone.opacity(level, dark: dark) + boost))
    }
}

extension ShapeStyle where Self == TextStyle {
    /// See `Theme.secondaryText`.
    static var secondaryText: TextStyle { Theme.secondaryText }
    /// See `Theme.tertiaryText`.
    static var tertiaryText: TextStyle { Theme.tertiaryText }
}

extension NSColor {
    /// `Theme.secondaryText` for text AppKit and Core Animation draw.
    static var secondaryText: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dark ? 1 : 0, alpha: TextTone.opacity(.secondary, dark: dark))
        }
    }
}

extension Font {
    /// Metadata: labels, units, short facts and status bars. 11 pt at the
    /// default text size, the smallest text the app draws.
    static let metadata = Font.subheadline
    /// Explanatory captions and notes: what something means, why a reading
    /// is missing, what a button will do. 12 pt, a size up from `metadata`,
    /// since these are read rather than scanned.
    static let explanation = Font.callout
    /// Rows of tables and lists: 12 pt.
    static let tableText = Font.callout
}

extension NSColor {
    /// The shade for fills and washes: the bright tone a data colour has in
    /// dark mode, in either appearance. Light mode deepens lines and text
    /// (see `Theme.data`) but keeps its washes pastel.
    var fillShade: NSColor {
        var shade = self
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            shade = usingColorSpace(.sRGB) ?? self
        }
        return shade
    }
}

extension Color {
    /// See `NSColor.fillShade`.
    var fillShade: Color {
        Color(nsColor: NSColor(self).fillShade)
    }
}

/// Graph with a border and a caption row, used in detail pages. With no
/// title or trailing text the caption row is left out, for a graph whose
/// caption sits in a row of its own with controls.
struct GraphPanel: View {
    var title: String
    var trailing: String
    var series: [GraphSeries]
    var maxValue: Double?
    var height: CGFloat = 200
    var stacked = false
    var minimumCeiling: Double = 0
    var maximumCeiling: Double = .infinity
    /// Labels the scale inside the graph; nil hides it.
    var axis: ((Double) -> String)?
    var axisUnits: GraphMath.AxisUnits = .plain
    /// Said after the top axis label (see `GraphView.axisNote`).
    var axisNote: String?
    /// Samples across; nil takes the page's window, as `GraphView` does.
    var capacity: Int?
    /// Puts the page's Fit collected data toggle in the time axis (`GraphFitToggle`).
    var offersFit = false

    var body: some View {
        let tint = series.last?.color ?? .accentColor
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty || !trailing.isEmpty {
                HStack {
                    Text(title).font(.metadata).foregroundStyle(.secondaryText)
                    Spacer()
                    Text(trailing).font(.metadata).foregroundStyle(.secondaryText).monospacedDigit()
                }
            }
            GraphView(series: series, maxValue: maxValue, capacity: capacity, glows: true, stacked: stacked,
                      minimumCeiling: minimumCeiling, maximumCeiling: maximumCeiling, axis: axis, axisUnits: axisUnits,
                      axisNote: axisNote, cornerRadius: 8)
                .frame(height: height)
                .plotFrame(tint: tint, wash: (0.12, 0.02), border: 0.30)
            TimeAxis(samples: capacity, offersFit: offersFit)
        }
    }
}

/// "Last 5 min … now" under a scrolling graph: the window it covers, named at
/// its oldest end, so graphs stacked on a page say outright that they cover
/// the same minutes. The span follows the update speed, so it stays true
/// when sampling is faster or slower, and the page's window when
/// Performance fits its graphs to what's been collected.
struct TimeAxis: View {
    @Environment(AppModel.self) private var model
    @Environment(\.graphWindow) private var window
    @Environment(\.offersGraphFit) private var fitOffered
    /// Samples across; nil takes the page's window (`graphWindow`).
    var samples: Int?
    /// Seconds per sample for a graph on its own cadence; nil follows the update speed.
    var interval: TimeInterval?

    /// Off under a graph too narrow for both ends' labels.
    var showsNow = true
    /// The page's main graph: its axis holds the Fit collected data toggle
    /// while the page offers one, so the window's label and the control
    /// that changes it sit together.
    var offersFit = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Last \(Format.timeSpan(Double(samples ?? window) * (interval ?? model.updateSpeed.rawValue)))")
            if offersFit, fitOffered { GraphFitToggle() }
            Spacer(minLength: 0)
            if showsNow { Text("now") }
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 2)
        // As tall with the toggle as without, so the page doesn't move when it goes.
        .frame(minHeight: offersFit ? GraphFitToggle.height : nil)
    }
}

/// Tiny graph for sidebars and the menu bar window.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double?
    var capacity = 60

    var body: some View {
        GraphView(series: [GraphSeries(values: values, color: color)], maxValue: maxValue,
                  capacity: capacity, showsGrid: false, lineWidth: 1.35, glows: true, cornerRadius: 3)
            .plotFrame(tint: color, wash: (0.16, 0.03), border: 0.5, lineWidth: 0.75, cornerRadius: 3)
    }
}

extension View {
    /// The plot area look shared by graphs: a pastel wash behind and a hairline
    /// border around, `wash` and `border` being opacities of the tint.
    func plotFrame(tint: Color, wash: (top: Double, bottom: Double) = (0.10, 0.02), border: Double = 0.25,
                   lineWidth: CGFloat = 1, cornerRadius: CGFloat = 8) -> some View {
        modifier(PlotFrame(tint: tint, wash: wash, border: border, lineWidth: lineWidth, cornerRadius: cornerRadius))
    }
}

/// See `plotFrame`. Light mode draws the border in the tint's deeper shade and
/// a little stronger, so a plot's edge holds up on a pale card; the wash
/// stays pastel in both.
private struct PlotFrame: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color
    var wash: (top: Double, bottom: Double)
    var border: Double
    var lineWidth: CGFloat
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let pastel = tint.fillShade
        content
            .background(LinearGradient(colors: [pastel.opacity(wash.top), pastel.opacity(wash.bottom)], startPoint: .top, endPoint: .bottom),
                        in: shape)
            .overlay(shape.strokeBorder(tint.opacity(colorScheme == .dark ? border : min(border * 1.8, 0.6)), lineWidth: lineWidth))
    }
}

extension EnvironmentValues {
    /// The narrowest a `Stat` gets. Compact strips lower it so more fit on a line.
    @Entry var statMinWidth: CGFloat = 110
}

/// Labelled value in the stats grids under each graph. Given a number and a
/// formatter, the value counts to each new reading instead of jumping.
struct Stat: View {
    private static let valueFont = NSFont.numeric(size: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .medium)

    @Environment(\.statMinWidth) private var minWidth
    var label: String
    var value: String
    var color: Color?
    var number: Double?
    var format: ((Double) -> String)?

    init(label: String, value: String, color: Color? = nil) {
        self.label = label
        self.value = value
        self.color = color
    }

    init(label: String, number: Double, color: Color? = nil, format: @escaping (Double) -> String) {
        self.label = label
        self.value = format(number)
        self.color = color
        self.number = number
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.metadata).foregroundStyle(.secondaryText)
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .background(Circle().fill(color.opacity(0.3)).frame(width: 11, height: 11))
                }
                if let number, let format {
                    AnimatedNumber(value: number, format: format, font: Self.valueFont)
                } else {
                    Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1)
                }
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
    }
}

/// Key/value row for the static-facts column on detail pages.
struct FactRow: View {
    var label: String
    var value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondaryText).gridColumnAlignment(.leading)
            Text(value).textSelection(.enabled).gridColumnAlignment(.leading)
        }
        .font(.callout)
    }
}

/// Horizontal stacked bar (memory composition, disk capacity).
struct StackedBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }

    var segments: [Segment]
    var total: Double
    var height: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(proxy.size.width * CGFloat(segment.value / max(total, 1)), 0))
                        .help("\(segment.label)")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Circular gauge with a glowing arc.
///
/// Drawn with Core Animation rather than SwiftUI shapes: the sweep then
/// animates in the render server, where a SwiftUI animation would re-run
/// layout for the whole window on every frame.
struct RingGauge: NSViewRepresentable {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 12

    func makeNSView(context: Context) -> RingGaugeView {
        RingGaugeView()
    }

    func updateNSView(_ view: RingGaugeView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color), lineWidth: lineWidth)
    }
}

final class RingGaugeView: NSView {
    private let ticks = CAShapeLayer()
    private let track = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let fill = CAGradientLayer()
    /// Bright bead riding the end of the arc.
    private let head = CALayer()
    private var lineWidth: CGFloat = 12
    private var fraction: CGFloat = 0
    private var color: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, glow, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
        }
        ticks.fillColor = nil
        arc.strokeColor = NSColor.black.cgColor
        fill.mask = arc
        glow.shadowOffset = .zero
        glow.shadowRadius = 7
        glow.shadowOpacity = 0.9
        glow.strokeEnd = 0
        arc.strokeEnd = 0
        head.shadowOffset = .zero
        head.shadowRadius = 6
        head.shadowOpacity = 1
        head.isHidden = true
        layer?.addSublayer(ticks)
        layer?.addSublayer(track)
        layer?.addSublayer(glow)
        layer?.addSublayer(fill)
        layer?.addSublayer(head)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(fraction: Double, color: NSColor, lineWidth: CGFloat) {
        let end = CGFloat(min(max(fraction.isFinite ? fraction : 0, 0), 1))
        let start = self.fraction
        self.fraction = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lineWidth != self.lineWidth {
            self.lineWidth = lineWidth
            needsLayout = true
        }
        if color != self.color {
            self.color = color
            applyColors()
        }
        head.isHidden = end < 0.005
        head.position = point(at: end)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        glow.strokeEnd = end
        arc.strokeEnd = end
        CATransaction.commit()

        guard start != end, !head.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let sweep = CAKeyframeAnimation(keyPath: "position")
        sweep.path = arcPath(from: start, to: end)
        sweep.duration = 0.45
        sweep.calculationMode = .paced
        sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
        head.add(sweep, forKey: "sweep")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The arc and ticks take the colour's shade for this appearance (deeper
    /// in light mode); the track and glow keep the bright fill shade.
    private func applyColors() {
        guard let color else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bright = color.fillShade
            track.strokeColor = bright.withAlphaComponent(0.14).cgColor
            glow.strokeColor = bright.withAlphaComponent(0.35).cgColor
            glow.shadowColor = bright.cgColor
            fill.colors = [(color.blended(withFraction: 0.45, of: .white) ?? color).cgColor, color.cgColor]
            ticks.strokeColor = color.withAlphaComponent(0.30).cgColor
            head.backgroundColor = (color.blended(withFraction: 0.75, of: .white) ?? .white).cgColor
            head.shadowColor = bright.cgColor
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Clockwise from twelve o'clock.
        let path = arcPath(from: 0, to: 1)
        for shape in [track, glow, arc] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        ticks.frame = bounds
        ticks.path = tickPath()
        ticks.lineWidth = 1
        fill.frame = bounds
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)
        let size = lineWidth * 0.62
        head.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        head.cornerRadius = size / 2
        head.shadowPath = CGPath(ellipseIn: head.bounds, transform: nil)
        head.position = point(at: fraction)
        CATransaction.commit()
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var radius: CGFloat { max((min(bounds.width, bounds.height) - lineWidth) / 2 - 2, 1) }

    /// Angle for a fraction of the dial: twelve o'clock, then clockwise.
    private func angle(_ fraction: CGFloat) -> CGFloat {
        .pi / 2 - 2 * .pi * fraction
    }

    private func point(at fraction: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle(fraction)), y: center.y + radius * sin(angle(fraction)))
    }

    private func arcPath(from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: angle(start), endAngle: angle(end), clockwise: end >= start)
        return path
    }

    /// Fine graduations just inside the track; every tenth is longer.
    private func tickPath() -> CGPath {
        let path = CGMutablePath()
        let outer = radius - lineWidth / 2 - 3
        for index in 0..<40 {
            let length: CGFloat = index % 10 == 0 ? 5 : 2.5
            let theta = angle(CGFloat(index) / 40)
            path.move(to: CGPoint(x: center.x + outer * cos(theta), y: center.y + outer * sin(theta)))
            path.addLine(to: CGPoint(x: center.x + (outer - length) * cos(theta), y: center.y + (outer - length) * sin(theta)))
        }
        return path
    }
}

/// A row of tiles that fill with load, one per core.
///
/// Core Animation again, so 18 tiles easing every second cost the app nothing.
struct CoreTileRow: NSViewRepresentable {
    var cpus: [Int]
    var usages: [Double]
    var color: Color

    static let tileSize = CGSize(width: 30, height: 44)
    static let spacing: CGFloat = 6

    static func width(for count: Int) -> CGFloat {
        CGFloat(count) * (tileSize.width + spacing) - spacing
    }

    func makeNSView(context: Context) -> CoreTileRowView {
        CoreTileRowView()
    }

    func updateNSView(_ view: CoreTileRowView, context: Context) {
        view.update(cpus: cpus, usages: usages, color: NSColor(color))
    }
}

final class CoreTileRowView: NSView {
    private struct Tile {
        /// Unclipped layer whose shadow is the glow around a busy core.
        let halo = CALayer()
        let box = CALayer()
        let level = CAGradientLayer()
    }

    private var tiles: [Tile] = []
    private var cpus: [Int] = []
    private var usages: [Double] = []
    private var color = NSColor.controlAccentColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(cpus: [Int], usages: [Double], color: NSColor) {
        self.cpus = cpus
        self.usages = usages
        self.color = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while tiles.count < usages.count {
            let tile = Tile()
            tile.halo.shadowOffset = .zero
            tile.halo.shadowRadius = 6
            tile.halo.shadowOpacity = 0
            tile.box.cornerRadius = 6
            tile.box.masksToBounds = true
            tile.level.anchorPoint = .zero
            tile.box.addSublayer(tile.level)
            layer?.addSublayer(tile.halo)
            layer?.addSublayer(tile.box)
            tiles.append(tile)
        }
        while tiles.count > usages.count {
            let tile = tiles.removeLast()
            tile.halo.removeFromSuperlayer()
            tile.box.removeFromSuperlayer()
        }
        layoutTiles()
        applyColors()
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        applyLoad()
        CATransaction.commit()
        updateToolTips()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColors()
        applyLoad()
        CATransaction.commit()
    }

    /// Washes and glows take the bright fill shade, levels the colour's shade
    /// for this appearance (deeper in light mode).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bright = color.fillShade
            let levelColors = [color.cgColor, color.withAlphaComponent(0.55).cgColor]
            for tile in tiles {
                tile.halo.shadowColor = bright.cgColor
                tile.box.backgroundColor = bright.withAlphaComponent(0.10).cgColor
                tile.level.colors = levelColors
            }
        }
    }

    /// Fills each tile to its load; the outline deepens with it.
    private func applyLoad() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (tile, usage) in zip(tiles, usages) {
                let load = CGFloat(min(max(usage, 0), 1))
                tile.level.bounds.size.height = CoreTileRow.tileSize.height * load
                tile.box.borderColor = color.withAlphaComponent(0.25 + 0.6 * load).cgColor
                tile.box.borderWidth = load > 0.75 ? 1.5 : 1
                tile.halo.shadowOpacity = load > 0.5 ? Float(load) * 0.8 : 0
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutTiles()
        CATransaction.commit()
        updateToolTips()
    }

    private func frame(ofTile index: Int) -> CGRect {
        let size = CoreTileRow.tileSize
        return CGRect(x: CGFloat(index) * (size.width + CoreTileRow.spacing), y: 0, width: size.width, height: size.height)
    }

    private func layoutTiles() {
        for (index, tile) in tiles.enumerated() {
            let rect = frame(ofTile: index)
            tile.halo.frame = rect
            tile.halo.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
            tile.box.frame = rect
            tile.level.position = .zero
            tile.level.bounds.size.width = rect.width
        }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (index, cpu) in cpus.enumerated() where usages.indices.contains(index) {
            addToolTip(frame(ofTile: index), owner: "CPU \(cpu): \(Format.percent(usages[index]))" as NSString, userData: nil)
        }
    }
}

/// Rounded panel that groups related readings, washed with a colour and
/// glowing in proportion to `glow` (for example, the load it shows).
struct Card<Content: View>: View {
    var tint: Color?
    /// 0...1. The halo brightens as this rises.
    var glow: Double = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            // Fills whatever height it's offered, so cards sharing a row
            // (see `FillGrid`) end level with each other.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardSurface(tint: tint, glow: glow))
    }
}

/// The card's background, drawn with Core Animation so the glow can ease
/// between readings without SwiftUI re-rendering anything.
private struct CardSurface: NSViewRepresentable {
    var tint: Color?
    var glow: Double

    func makeNSView(context: Context) -> CardSurfaceView {
        CardSurfaceView()
    }

    func updateNSView(_ view: CardSurfaceView, context: Context) {
        // Washes stay pastel in light mode: only lines and text deepen.
        view.update(tint: tint.map { NSColor($0).fillShade }, glow: glow)
    }
}

final class CardSurfaceView: NSView {
    private static let radius: CGFloat = 12

    private let halo = CALayer()
    /// Hides the halo under the card itself, so only the outer glow shows.
    private let haloMask = CAShapeLayer()
    private let surface = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private var tint: NSColor?
    private var glow: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        halo.shadowOffset = .zero
        halo.shadowRadius = 18
        halo.shadowOpacity = 0
        haloMask.fillRule = .evenOdd
        halo.mask = haloMask
        surface.cornerRadius = Self.radius
        surface.masksToBounds = true
        surface.borderWidth = 1
        surface.startPoint = CGPoint(x: 0, y: 1)
        surface.endPoint = CGPoint(x: 1, y: 0)
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        surface.addSublayer(sheen)
        layer?.addSublayer(halo)
        layer?.addSublayer(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tint: NSColor?, glow: Double) {
        let restyle = tint != self.tint
        self.tint = tint
        self.glow = min(max(glow.isFinite ? glow : 0, 0), 1)
        if restyle { applyColors() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        halo.shadowOpacity = tint == nil ? 0 : Float(0.10 + 0.55 * self.glow)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.borderColor = borderColor.cgColor
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds
        let card = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        halo.shadowPath = card
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -60, dy: -60))
        outside.addPath(card)
        haloMask.frame = halo.bounds
        haloMask.path = outside
        surface.frame = bounds
        sheen.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private var borderColor: NSColor {
        (tint ?? .secondaryLabelColor).withAlphaComponent(tint == nil ? 0.20 : 0.25 + 0.35 * glow)
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = tint ?? .secondaryLabelColor
            surface.colors = [base.withAlphaComponent(tint == nil ? 0.10 : 0.16).cgColor, base.withAlphaComponent(0.03).cgColor]
            surface.borderColor = borderColor.cgColor
            halo.shadowColor = base.cgColor
            let light = NSColor.white.withAlphaComponent(0.16).cgColor
            sheen.colors = [NSColor.clear.cgColor, light, NSColor.clear.cgColor]
        }
        CATransaction.commit()
    }
}

/// A row in a "top processes" list: icon, name, value, and a bar showing
/// the value relative to the busiest row.
struct ProcessBarRow: View {
    /// A row's height: the icon or a line of table text, whichever is
    /// taller, and the padding, so a list can keep room for rows it isn't showing.
    static let height = max(16, ceil(NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .callout)))) + 6

    var icon: NSImage
    var name: String
    var value: String
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            Text(name).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.secondaryText)
        }
        .font(.tableText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            // The bar sits behind text, so it keeps the pastel fill shade.
            let bar = color.fillShade
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [bar.opacity(0.30), bar.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}
