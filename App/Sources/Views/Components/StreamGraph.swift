import AppKit
import OTMKit
import SwiftUI

extension EnvironmentValues {
    /// Seconds between samples: how long a graph takes to scroll one step.
    @Entry var sampleInterval: TimeInterval = 1
    /// Scroll graphs continuously between samples instead of a step at a time.
    @Entry var streamsGraphs = true
}

struct GraphSeries {
    var values: [Double]
    var color: Color
    var fill = true
    var dashed = false
}

/// A task-manager graph: newest value on the right, older values sliding left.
///
/// Drawn by `StreamGraphView` with Core Animation. Each sample rebuilds the
/// paths once, and the render server then scrolls them one step to the left
/// over the sampling interval, so the line streams in instead of jumping.
struct GraphView: NSViewRepresentable {
    var series: [GraphSeries]
    /// Fixed top of the scale; nil auto-scales to the visible data.
    var maxValue: Double?
    /// Samples across the full width.
    var capacity = AppModel.graphSpan
    var showsGrid = true
    var lineWidth: CGFloat = 1.5
    /// Bloom under each line and a glowing marker on the newest value.
    var glows = false
    /// Draw each series on top of the ones before it, as filled bands.
    var stacked = false
    /// Auto-scaled graphs never zoom in further than this.
    var minimumCeiling: Double = 0
    /// ...or out further than this, so a noisy sample can't flatten the rest.
    var maximumCeiling: Double = .infinity
    /// Labels the top and middle of the scale; nil hides the axis.
    var axis: ((Double) -> String)?
    /// Units the axis is labelled in, so its top lands on a round number.
    var axisUnits: GraphMath.AxisUnits = .plain
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> StreamGraphView {
        StreamGraphView()
    }

    func updateNSView(_ view: StreamGraphView, context: Context) {
        let configuration = StreamGraphView.Configuration(
            lines: series.map {
                StreamGraphView.Line(values: Array($0.values.suffix(capacity + 1)), color: NSColor($0.color), fill: $0.fill, dashed: $0.dashed)
            },
            maxValue: maxValue, capacity: max(capacity, 2), showsGrid: showsGrid, lineWidth: lineWidth, glows: glows,
            stacked: stacked, minimumCeiling: minimumCeiling, maximumCeiling: maximumCeiling,
            axis: axis, axisUnits: axisUnits, cornerRadius: cornerRadius
        )
        view.update(configuration, interval: context.environment.sampleInterval, streams: context.environment.streamsGraphs)
    }
}

final class StreamGraphView: NSView {
    struct Line {
        var values: [Double]
        var color: NSColor
        var fill: Bool
        var dashed: Bool
    }

    struct Configuration {
        var lines: [Line]
        var maxValue: Double?
        var capacity: Int
        var showsGrid: Bool
        var lineWidth: CGFloat
        var glows: Bool
        var stacked: Bool
        var minimumCeiling: Double
        var maximumCeiling: Double
        var axis: ((Double) -> String)?
        var axisUnits: GraphMath.AxisUnits
        var cornerRadius: CGFloat
    }

    /// Layers for one series. The fill and line live in `scroller`; the
    /// head marker sits outside the clipped plot so it can straddle the edge.
    private final class SeriesLayers {
        let fill = CAGradientLayer()
        let fillMask = CAShapeLayer()
        let line = CAShapeLayer()
        let head = CALayer()
        let halo = CALayer()
        let dot = CALayer()

        init() {
            fill.mask = fillMask
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
            line.shadowOffset = .zero
            head.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            halo.frame = head.bounds
            halo.cornerRadius = 6
            dot.frame = head.bounds.insetBy(dx: 3, dy: 3)
            dot.cornerRadius = 3
            dot.shadowOffset = .zero
            dot.shadowRadius = 4
            dot.shadowOpacity = 1
            dot.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 6, height: 6), transform: nil)
            head.addSublayer(halo)
            head.addSublayer(dot)
        }

        func removeFromSuperlayers() {
            [fill, line, head].forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Screen-space shape of one series, ready to turn into paths.
    private struct Trace {
        var ys: [CGFloat]
        var tangents: [CGFloat]
    }

    private let plot = CALayer()
    private let grid = CAShapeLayer()
    private let scroller = CALayer()
    private let columns = CAShapeLayer()
    private let topLabel = CATextLayer()
    private let midLabel = CATextLayer()
    private var series: [SeriesLayers] = []

    private var configuration: Configuration?
    private var lastValues: [[Double]] = []
    private var lastSize: CGSize = .zero
    private var ceiling: Double = 1
    private var hasDrawn = false
    /// Counts samples so the vertical grid lines scroll with the data.
    private var sampleIndex = 0
    private var interval: TimeInterval = 1
    private var streams = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plot.masksToBounds = true
        scroller.anchorPoint = .zero
        scroller.masksToBounds = false
        // The scroller only ever moves sideways between samples, so a cached
        // bitmap of it (glow included) slides for free in the render server.
        scroller.shouldRasterize = true
        for shape in [grid, columns] {
            shape.fillColor = nil
            shape.lineWidth = 0.5
        }
        for label in [topLabel, midLabel] {
            label.alignmentMode = .left
            label.shadowOpacity = 0.5
            label.shadowRadius = 2
            label.shadowOffset = .zero
        }
        scroller.addSublayer(columns)
        plot.addSublayer(grid)
        plot.addSublayer(scroller)
        layer?.addSublayer(plot)
        layer?.addSublayer(topLabel)
        layer?.addSublayer(midLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Graph")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ configuration: Configuration, interval: TimeInterval, streams: Bool) {
        let values = configuration.lines.map(\.values)
        let isNewSample = hasDrawn && values != lastValues
            && configuration.lines.count == self.configuration?.lines.count
            && configuration.capacity == self.configuration?.capacity
        if values != lastValues { sampleIndex += 1 }
        self.configuration = configuration
        self.interval = interval
        self.streams = streams
        lastValues = values
        if let newest = configuration.lines.first?.values.last {
            setAccessibilityValue(String(format: "%.2f", newest))
        }
        render(newSample: isNewSample)
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        render(newSample: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        scroller.rasterizationScale = scale
        topLabel.contentsScale = scale
        midLabel.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render(newSample: false)
    }

    // MARK: - Drawing

    private var headInset: CGFloat { configuration?.glows == true ? 6 : 0 }

    private var verticalPadding: CGFloat {
        guard let configuration else { return 2 }
        return configuration.glows ? 4 : max(configuration.lineWidth, 1.5)
    }

    private func render(newSample: Bool) {
        guard let configuration, bounds.width > 8, bounds.height > 8 else { return }
        lastSize = bounds.size
        let plotRect = CGRect(x: 0, y: 0, width: bounds.width - headInset, height: bounds.height)
        let step = plotRect.width / CGFloat(configuration.capacity - 1)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scrolls = newSample && streams && !reduceMotion

        let raw = configuration.lines.map(\.values)
        let shown = configuration.stacked ? GraphMath.stack(raw) : raw
        let peak = shown.joined().max() ?? 0
        let previousCeiling = ceiling
        ceiling = configuration.maxValue
            ?? min(GraphMath.ceiling(peak: peak, floor: configuration.minimumCeiling, units: configuration.axisUnits),
                   configuration.maximumCeiling)
        let rescales = hasDrawn && newSample && previousCeiling != ceiling && !reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = configuration.cornerRadius
        layer?.masksToBounds = configuration.cornerRadius > 0
        plot.frame = plotRect
        scroller.frame = CGRect(x: 0, y: 0, width: plotRect.width + 2 * step + 16, height: plotRect.height)
        scroller.rasterizationScale = window?.backingScaleFactor ?? 2
        drawGrid(in: plotRect, step: step, configuration: configuration)
        syncSeriesLayers(count: shown.count)

        var rescaleAnimations: [(CAShapeLayer, CGPath)] = []
        for (index, values) in shown.enumerated() {
            let line = configuration.lines[index]
            let layers = series[index]
            let trace = makeTrace(values, ceiling: ceiling, height: plotRect.height)
            let below = configuration.stacked && index > 0
                ? makeTrace(shown[index - 1], ceiling: ceiling, height: plotRect.height) : nil
            let firstX = plotRect.width + step - CGFloat(values.count - 1) * step
            let paths = makePaths(trace, below: below, firstX: firstX, step: step)

            if rescales {
                let oldTrace = makeTrace(values, ceiling: previousCeiling, height: plotRect.height)
                let oldBelow = below == nil ? nil : makeTrace(shown[index - 1], ceiling: previousCeiling, height: plotRect.height)
                let old = makePaths(oldTrace, below: oldBelow, firstX: firstX, step: step)
                rescaleAnimations.append((layers.line, old.line))
                rescaleAnimations.append((layers.fillMask, old.area))
            }
            style(layers, line: line, configuration: configuration, paths: paths)
            placeHead(layers, line: line, trace: trace, edge: plotRect.maxX, animated: scrolls)
        }
        scroller.position = CGPoint(x: -step, y: 0)
        CATransaction.commit()

        if scrolls {
            let scroll = CABasicAnimation(keyPath: "position.x")
            scroll.fromValue = 0
            scroll.toValue = -step
            scroll.duration = interval
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            scroll.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            scroller.add(scroll, forKey: "scroll")
        } else {
            scroller.removeAnimation(forKey: "scroll")
        }
        for (shape, from) in rescaleAnimations {
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = from
            morph.duration = 0.45
            morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(morph, forKey: "rescale")
        }
        hasDrawn = !shown.isEmpty
    }

    private func syncSeriesLayers(count: Int) {
        while series.count < count {
            let layers = SeriesLayers()
            scroller.addSublayer(layers.fill)
            scroller.addSublayer(layers.line)
            layer?.addSublayer(layers.head)
            series.append(layers)
        }
        while series.count > count {
            series.removeLast().removeFromSuperlayers()
        }
    }

    /// Screen y for each value, plus the curve's tangents.
    private func makeTrace(_ values: [Double], ceiling: Double, height: CGFloat) -> Trace {
        let padding = verticalPadding
        let usable = max(height - 2 * padding, 1)
        let ys = values.map { value -> CGFloat in
            let fraction = value.isFinite ? min(max(value / max(ceiling, .leastNonzeroMagnitude), 0), 1) : 0
            return padding + usable * CGFloat(fraction)
        }
        let tangents = GraphMath.monotoneTangents(ys.map(Double.init)).map { CGFloat($0) }
        return Trace(ys: ys, tangents: tangents)
    }

    /// The line along `trace`, and the area under it (down to the baseline,
    /// or down to `below` for a stacked band).
    private func makePaths(_ trace: Trace, below: Trace?, firstX: CGFloat, step: CGFloat) -> (line: CGPath, area: CGPath) {
        let line = CGMutablePath()
        guard !trace.ys.isEmpty else { return (line, line) }
        let lastX = firstX + CGFloat(trace.ys.count - 1) * step
        line.move(to: CGPoint(x: firstX, y: trace.ys[0]))
        appendCurve(trace, to: line, firstX: firstX, step: step, reversed: false)

        let area = CGMutablePath()
        area.addPath(line)
        if let below, below.ys.count == trace.ys.count {
            area.addLine(to: CGPoint(x: lastX, y: below.ys[below.ys.count - 1]))
            appendCurve(below, to: area, firstX: firstX, step: step, reversed: true)
        } else {
            area.addLine(to: CGPoint(x: lastX, y: 0))
            area.addLine(to: CGPoint(x: firstX, y: 0))
        }
        area.closeSubpath()
        return (line, area)
    }

    /// Cubic Bézier segments equivalent to the monotone Hermite curve.
    private func appendCurve(_ trace: Trace, to path: CGMutablePath, firstX: CGFloat, step: CGFloat, reversed: Bool) {
        let ys = trace.ys
        let tangents = trace.tangents
        guard ys.count > 1 else { return }
        let third = step / 3
        let indices = reversed ? Array((1..<ys.count).reversed()) : Array(0..<ys.count - 1)
        for index in indices {
            let next = reversed ? index - 1 : index + 1
            let direction: CGFloat = reversed ? -1 : 1
            let x = firstX + CGFloat(index) * step
            let nextX = firstX + CGFloat(next) * step
            path.addCurve(
                to: CGPoint(x: nextX, y: ys[next]),
                control1: CGPoint(x: x + direction * third, y: ys[index] + direction * tangents[index] / 3),
                control2: CGPoint(x: nextX - direction * third, y: ys[next] - direction * tangents[next] / 3)
            )
        }
    }

    private func style(_ layers: SeriesLayers, line: Line, configuration: Configuration, paths: (line: CGPath, area: CGPath)) {
        let color = line.color
        layers.line.path = paths.line
        layers.line.strokeColor = color.cgColor
        layers.line.lineWidth = configuration.lineWidth
        layers.line.lineDashPattern = line.dashed ? [4, 3] : nil
        layers.line.shadowColor = color.cgColor
        layers.line.shadowRadius = configuration.glows ? 5 : 0
        layers.line.shadowOpacity = configuration.glows ? 0.95 : 0

        let filled = configuration.stacked || line.fill
        layers.fill.isHidden = !filled
        layers.fill.frame = scroller.bounds
        layers.fillMask.frame = layers.fill.bounds
        layers.fillMask.path = paths.area
        let top: CGFloat = configuration.stacked ? 0.70 : (configuration.glows ? 0.45 : 0.35)
        let bottom: CGFloat = configuration.stacked ? 0.30 : 0
        layers.fill.colors = [color.withAlphaComponent(top).cgColor, color.withAlphaComponent(bottom).cgColor]
        layers.fill.startPoint = CGPoint(x: 0.5, y: 1)
        layers.fill.endPoint = CGPoint(x: 0.5, y: 0)
    }

    /// Puts the marker on the curve at the plot's right edge. While the graph
    /// scrolls, the marker glides along the newest segment in step with it.
    private func placeHead(_ layers: SeriesLayers, line: Line, trace: Trace, edge: CGFloat, animated: Bool) {
        let isTop = configuration?.stacked != true || layers === series.last
        let visible = configuration?.glows == true && !line.dashed && isTop && !trace.ys.isEmpty
        layers.head.isHidden = !visible
        guard visible, let last = trace.ys.last else { return }
        layers.halo.backgroundColor = line.color.withAlphaComponent(0.28).cgColor
        layers.dot.backgroundColor = line.color.cgColor
        layers.dot.shadowColor = line.color.cgColor
        layers.head.position = CGPoint(x: edge, y: last)
        layers.head.removeAnimation(forKey: "glide")

        let count = trace.ys.count
        guard animated, count > 1 else { return }
        let keyframes = (0...12).map { frame -> NSValue in
            let y = GraphMath.hermite(
                from: Double(trace.ys[count - 2]), to: Double(last),
                startTangent: Double(trace.tangents[count - 2]), endTangent: Double(trace.tangents[count - 1]), at: Double(frame) / 12
            )
            return NSValue(point: CGPoint(x: edge, y: y))
        }
        let glide = CAKeyframeAnimation(keyPath: "position")
        glide.values = keyframes
        glide.duration = interval
        glide.calculationMode = .linear
        glide.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        layers.head.add(glide, forKey: "glide")
    }

    private func drawGrid(in plotRect: CGRect, step: CGFloat, configuration: Configuration) {
        grid.isHidden = !configuration.showsGrid
        columns.isHidden = !configuration.showsGrid
        var lineColor = NSColor.labelColor.cgColor
        var labelColor = NSColor.secondaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            lineColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            labelColor = NSColor.secondaryLabelColor.cgColor
        }
        let padding = verticalPadding
        let usable = plotRect.height - 2 * padding
        if configuration.showsGrid {
            let rows = CGMutablePath()
            for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
                let y = padding + usable * fraction
                rows.move(to: CGPoint(x: 0, y: y))
                rows.addLine(to: CGPoint(x: plotRect.width, y: y))
            }
            grid.frame = plot.bounds
            grid.path = rows
            grid.strokeColor = lineColor

            // Vertical lines belong to sample times, so they scroll with the data.
            let spacing = max(configuration.capacity / 10, 1)
            let newestX = plotRect.width + step
            let verticals = CGMutablePath()
            var age = sampleIndex % spacing
            while newestX - CGFloat(age) * step >= -step {
                let x = newestX - CGFloat(age) * step
                verticals.move(to: CGPoint(x: x, y: 0))
                verticals.addLine(to: CGPoint(x: x, y: plotRect.height))
                age += spacing
            }
            columns.frame = scroller.bounds
            columns.path = verticals
            columns.strokeColor = lineColor
        }

        let axis = configuration.axis
        topLabel.isHidden = axis == nil
        midLabel.isHidden = axis == nil
        guard let axis else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        for (label, value, y) in [(topLabel, ceiling, plotRect.height - padding), (midLabel, ceiling / 2, padding + usable / 2)] {
            let color = NSColor(cgColor: labelColor) ?? .secondaryLabelColor
            let text = NSAttributedString(string: axis(value), attributes: [.font: font, .foregroundColor: color])
            if (label.string as? NSAttributedString)?.string != text.string, hasDrawn {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.3
                label.add(fade, forKey: "fade")
            }
            label.string = text
            label.shadowColor = NSColor.windowBackgroundColor.cgColor
            label.frame = CGRect(x: 5, y: y - 14, width: max(plotRect.width - 10, 0), height: 14)
        }
    }
}
