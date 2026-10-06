import OTMKit
import SwiftUI

enum Theme {
    static let cpu = Color(red: 0.24, green: 0.56, blue: 1.00)
    static let memory = Color(red: 0.64, green: 0.42, blue: 0.96)
    static let disk = Color(red: 0.20, green: 0.74, blue: 0.44)
    static let diskSecondary = Color(red: 0.55, green: 0.86, blue: 0.40)
    static let network = Color(red: 0.98, green: 0.55, blue: 0.20)
    static let networkSecondary = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let gpu = Color(red: 0.10, green: 0.74, blue: 0.80)
    static let power = Color(red: 0.95, green: 0.72, blue: 0.12)

    // Memory composition.
    static let wired = Color(red: 0.93, green: 0.36, blue: 0.62)
    static let compressed = Color(red: 0.98, green: 0.62, blue: 0.24)
    static let cached = Color(red: 0.32, green: 0.70, blue: 0.86)
    static let swap = Color(red: 0.96, green: 0.42, blue: 0.36)

    // Power components.
    static let neuralEngine = Color(red: 0.90, green: 0.40, blue: 0.86)
    static let dram = Color(red: 0.62, green: 0.50, blue: 0.98)
    static let restOfSystem = Color(red: 0.62, green: 0.58, blue: 0.48)

    /// Everything not broken out on its own.
    static let other = Color(white: 0.50)

    /// Distinct colours for "by app" series, in rank order.
    static let series: [Color] = [
        Color(red: 0.26, green: 0.58, blue: 1.00),
        Color(red: 0.98, green: 0.58, blue: 0.22),
        Color(red: 0.16, green: 0.80, blue: 0.70),
        Color(red: 0.94, green: 0.40, blue: 0.62),
        Color(red: 0.62, green: 0.82, blue: 0.30),
        Color(red: 0.70, green: 0.52, blue: 0.98),
    ]

    static func series(_ index: Int) -> Color {
        series[index % series.count]
    }

    /// Colour for a core tier: the fastest tier (level 0) gets the CPU blue.
    static func tier(_ level: Int) -> Color {
        level == 0 ? cpu : Color(red: 0.22, green: 0.82, blue: 0.86)
    }

    static func pressure(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .green
    }
}

/// Graph with a border and a caption row, used in detail pages.
struct GraphPanel: View {
    var title: String
    var trailing: String
    var series: [GraphSeries]
    var maxValue: Double?
    var height: CGFloat = 200
    var stacked = false
    var minimumCeiling: Double = 0
    /// Labels the scale inside the graph; nil hides it.
    var axis: ((Double) -> String)?
    var axisUnits: GraphMath.AxisUnits = .plain
    var capacity = AppModel.graphSpan

    var body: some View {
        let tint = series.last?.color ?? .accentColor
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GraphView(series: series, maxValue: maxValue, capacity: capacity, glows: true, stacked: stacked,
                      minimumCeiling: minimumCeiling, axis: axis, axisUnits: axisUnits, cornerRadius: 8)
                .frame(height: height)
                .background(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.30)))
        }
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
                  capacity: capacity, showsGrid: false, lineWidth: 1.2, cornerRadius: 3)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.5), lineWidth: 0.75))
    }
}

/// Labelled value in the stats grids under each graph. Given a number and a
/// formatter, the value counts to each new reading instead of jumping.
struct Stat: View {
    private static let valueFont = NSFont.numeric(size: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .medium)

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
            Text(label).font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 110, alignment: .leading)
    }
}

/// Key/value row for the static-facts column on detail pages.
struct FactRow: View {
    var label: String
    var value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
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
        track.strokeColor = color.withAlphaComponent(0.14).cgColor
        glow.strokeColor = color.withAlphaComponent(0.35).cgColor
        glow.shadowColor = color.cgColor
        fill.colors = [(color.blended(withFraction: 0.45, of: .white) ?? color).cgColor, color.cgColor]
        ticks.strokeColor = color.withAlphaComponent(0.30).cgColor
        head.backgroundColor = (color.blended(withFraction: 0.75, of: .white) ?? .white).cgColor
        head.shadowColor = color.cgColor
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
        for tile in tiles {
            tile.halo.shadowColor = color.cgColor
            tile.box.backgroundColor = color.withAlphaComponent(0.10).cgColor
            tile.level.colors = [color.cgColor, color.withAlphaComponent(0.55).cgColor]
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (tile, usage) in zip(tiles, usages) {
            let load = CGFloat(min(max(usage, 0), 1))
            tile.level.bounds.size.height = CoreTileRow.tileSize.height * load
            tile.box.borderColor = color.withAlphaComponent(0.25 + 0.6 * load).cgColor
            tile.box.borderWidth = load > 0.75 ? 1.5 : 1
            tile.halo.shadowOpacity = load > 0.5 ? Float(load) * 0.8 : 0
        }
        CATransaction.commit()
        updateToolTips()
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        view.update(tint: tint.map(NSColor.init), glow: glow)
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
        surface.borderColor = borderColor.cgColor
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
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}
