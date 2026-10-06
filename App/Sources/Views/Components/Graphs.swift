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

    /// Colour for a core tier: the fastest tier (level 0) gets the CPU blue.
    static func tier(_ level: Int) -> Color {
        level == 0 ? cpu : Color(red: 0.22, green: 0.82, blue: 0.86)
    }

    static func pressure(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .green
    }
}

struct GraphSeries {
    var values: [Double]
    var color: Color
    var fill = true
    var dashed = false
}

/// A scrolling line graph in the style of a task manager: newest value on the
/// right edge, older values sliding left, over a light grid.
struct GraphView: View {
    var series: [GraphSeries]
    /// Fixed top of the scale; nil auto-scales to the visible data.
    var maxValue: Double?
    var capacity = AppModel.historyCapacity
    var showsGrid = true
    var lineWidth: CGFloat = 1.5
    /// Soft bloom under each line and a marker on the newest value.
    var glows = false

    var body: some View {
        Canvas { context, size in
            let scale = resolvedMax
            if showsGrid { drawGrid(in: &context, size: size) }
            // Leave room for the newest-value marker on the right edge.
            let plot = CGSize(width: size.width - (glows ? 6 : 0), height: size.height)
            for line in series where !line.values.isEmpty {
                draw(line, scale: scale, in: &context, size: plot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Graph")
        .accessibilityValue(series.first?.values.last.map { String(format: "%.1f", $0) } ?? "no data")
    }

    var resolvedMax: Double {
        if let maxValue { return maxValue }
        let peak = series.flatMap(\.values).max() ?? 0
        return Self.niceCeiling(peak)
    }

    /// Rounds up to 1, 2 or 5 × 10ⁿ so auto-scaled graphs land on tidy values.
    nonisolated static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for step in [1.0, 2, 5, 10] where value <= step * base {
            return step * base
        }
        return 10 * base
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for row in 1..<4 {
            let y = size.height * CGFloat(row) / 4
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for column in 1..<10 {
            let x = size.width * CGFloat(column) / 10
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
    }

    /// Rounds the corners through each midpoint. Unlike a spline it never
    /// overshoots, so a curve can't poke above 100% or below zero.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 1..<points.count - 1 {
            let next = points[index + 1]
            let mid = CGPoint(x: (points[index].x + next.x) / 2, y: (points[index].y + next.y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private func draw(_ line: GraphSeries, scale: Double, in context: inout GraphicsContext, size: CGSize) {
        let values = line.values.suffix(capacity)
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let startX = size.width - step * CGFloat(values.count - 1)
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let clamped = min(max(value / max(scale, .leastNonzeroMagnitude), 0), 1)
            return CGPoint(x: startX + step * CGFloat(index), y: size.height * (1 - clamped))
        }

        let points = values.enumerated().map { point($0.offset, $0.element) }
        let stroke = Self.smoothPath(through: points)

        if line.fill, points.count > 1 {
            var area = stroke
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: startX, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [line.color.opacity(glows ? 0.45 : 0.35), line.color.opacity(0.0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: line.dashed ? [4, 3] : [])
        if glows {
            // Wide translucent strokes fake a bloom; a real blur filter is
            // rasterised on the CPU every frame and costs far more.
            for (width, opacity) in [(lineWidth * 5, 0.08), (lineWidth * 2.8, 0.16)] {
                var wide = style
                wide.lineWidth = width
                context.stroke(stroke, with: .color(line.color.opacity(opacity)), style: wide)
            }
        }
        context.stroke(stroke, with: .color(line.color), style: style)

        if glows, !line.dashed, let last = points.last {
            let halo = CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: halo), with: .color(line.color.opacity(0.28)))
            context.fill(Path(ellipseIn: halo.insetBy(dx: 2.5, dy: 2.5)), with: .color(line.color))
        }
    }
}

/// Graph with a border and an optional caption row, used in detail pages.
struct GraphPanel: View {
    var title: String
    var trailing: String
    var series: [GraphSeries]
    var maxValue: Double?
    var height: CGFloat = 200

    var body: some View {
        let tint = series.first?.color ?? .accentColor
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GraphView(series: series, maxValue: maxValue, glows: true)
                .frame(height: height)
                .background(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.30)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                  capacity: capacity, showsGrid: false, lineWidth: 1.2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.5), lineWidth: 0.75))
    }
}

/// Labelled value in the stats grids under each graph.
struct Stat: View {
    var label: String
    var value: String
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1)
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
    private let track = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let fill = CAGradientLayer()
    private var lineWidth: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, glow, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
        }
        arc.strokeColor = NSColor.black.cgColor
        fill.mask = arc
        glow.shadowOffset = .zero
        glow.shadowRadius = 7
        glow.shadowOpacity = 0.9
        glow.strokeEnd = 0
        arc.strokeEnd = 0
        layer?.addSublayer(track)
        layer?.addSublayer(glow)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(fraction: Double, color: NSColor, lineWidth: CGFloat) {
        let end = CGFloat(min(max(fraction.isFinite ? fraction : 0, 0), 1))
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
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        glow.strokeEnd = end
        arc.strokeEnd = end
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = (min(bounds.width, bounds.height) - lineWidth) / 2 - 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Clockwise from twelve o'clock.
        let path = CGMutablePath()
        path.addArc(center: center, radius: max(radius, 1), startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, glow, arc] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        fill.frame = bounds
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)
        CATransaction.commit()
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

/// Rounded panel that groups related readings, optionally washed with a colour.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(colors: [(tint ?? .secondary).opacity(0.10), (tint ?? .secondary).opacity(0.03)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((tint ?? .secondary).opacity(0.22)))
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
