import AppKit
import OTMKit
import SwiftUI

extension EnvironmentValues {
    /// Seconds between samples: how long a graph takes to scroll one step.
    @Entry var sampleInterval: TimeInterval = 1
    /// Scroll graphs continuously between samples instead of a step at a time.
    @Entry var streamsGraphs = true
    /// Samples across the graphs on a page that share its window (those
    /// that don't name a capacity of their own) and under their time axes:
    /// `AppModel.graphSpan`, or fewer while Performance fits its graphs to
    /// what's been collected (`GraphFit`).
    @Entry var graphWindow = AppModel.graphSpan
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
/// Until the window fills, the stretch before the first sample gets a light
/// neutral wash with a faint hatch (`UnrecordedLook`), a dashed line marks
/// where recording started, and a graph with an axis says at its foot how
/// much of its window it has ("40 s collected · 5 min window"), so the gap
/// isn't read as zero without outweighing the little data there is.
struct GraphView: NSViewRepresentable {
    var series: [GraphSeries]
    /// Fixed top of the scale; nil auto-scales to the visible data.
    var maxValue: Double?
    /// Samples across the full width; nil takes the page's window, `graphWindow`.
    var capacity: Int?
    var showsGrid = true
    /// A little over the grid's and the unrecorded hatch's, so a low trace
    /// still stands out from them.
    var lineWidth: CGFloat = 1.75
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
    /// Said after the top label, such as "auto scale" for a top that isn't fixed.
    var axisNote: String?
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> StreamGraphView {
        StreamGraphView()
    }

    func updateNSView(_ view: StreamGraphView, context: Context) {
        let capacity = capacity ?? context.environment.graphWindow
        let configuration = StreamGraphView.Configuration(
            lines: series.map {
                StreamGraphView.Line(values: Array($0.values.suffix(capacity + 1)), color: NSColor($0.color), fill: $0.fill, dashed: $0.dashed)
            },
            maxValue: maxValue, capacity: max(capacity, 2), showsGrid: showsGrid, lineWidth: lineWidth, glows: glows,
            stacked: stacked, minimumCeiling: minimumCeiling, maximumCeiling: maximumCeiling,
            axis: axis, axisUnits: axisUnits, axisNote: axisNote, cornerRadius: cornerRadius
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
        var axisNote: String?
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
            // A tight halo and a faint shadow: enough to find the newest
            // value, not so much that it blurs the line it sits on.
            halo.frame = head.bounds.insetBy(dx: 1.5, dy: 1.5)
            halo.cornerRadius = 4.5
            dot.frame = head.bounds.insetBy(dx: 3, dy: 3)
            dot.cornerRadius = 3
            dot.shadowOffset = .zero
            dot.shadowRadius = 1.5
            dot.shadowOpacity = 0.45
            dot.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 6, height: 6), transform: nil)
            head.addSublayer(halo)
            head.addSublayer(dot)
        }

        func removeFromSuperlayers() {
            [fill, line, head].forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Screen-space shape of one series, ready to turn into paths. In
    /// `Double`, as `GraphMath` works, so nothing is converted per point.
    private struct Trace {
        var ys: [Double]
        var tangents: [Double]
    }

    /// The axis labels' size. 12 pt, the app's size for explanations, would
    /// leave no room for the caption under the middle label in a 72-point graph.
    private static let captionFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    /// The top label's note ("auto scale").
    private static let noteFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private let plot = CALayer()
    private let grid = CAShapeLayer()
    private let scroller = CALayer()
    private let columns = CAShapeLayer()
    /// The stretch before the first sample, washed and faintly hatched. It lives in
    /// the scroller, so it slides with the data; the hatch is built once per
    /// size and each sample only moves layers.
    private let unrecorded = CALayer()
    private let hatch = CAShapeLayer()
    /// Dashed line at the first sample: where recording started.
    private let boundary = CAShapeLayer()
    /// "45 s collected · 5 min window", at the foot of the unrecorded stretch.
    private let captionBadge = CALayer()
    private let captionLabel = CATextLayer()
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
    /// The size the hatch and boundary paths were built for.
    private var hatchSize: CGSize = .zero
    /// The caption's strings and their widths, measured once per string.
    private var captionWidths: [String: CGFloat] = [:]
    /// What the caption shows, with the appearance it was coloured for.
    private var shownCaption = ""
    /// The caption VoiceOver reads as help, kept so it's set only on change.
    private var accessibilityCaption: String?

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
        unrecorded.anchorPoint = .zero
        unrecorded.masksToBounds = true
        hatch.anchorPoint = .zero
        hatch.fillColor = nil
        hatch.lineWidth = UnrecordedLook.hatchWidth
        unrecorded.addSublayer(hatch)
        boundary.anchorPoint = .zero
        boundary.fillColor = nil
        boundary.lineWidth = 1
        boundary.lineDashPattern = [3, 3]
        captionBadge.anchorPoint = .zero
        captionBadge.cornerRadius = 4
        captionBadge.isHidden = true
        captionLabel.anchorPoint = .zero
        captionLabel.alignmentMode = .left
        captionBadge.addSublayer(captionLabel)
        scroller.addSublayer(columns)
        scroller.addSublayer(unrecorded)
        scroller.addSublayer(boundary)
        plot.addSublayer(grid)
        plot.addSublayer(scroller)
        layer?.addSublayer(plot)
        layer?.addSublayer(captionBadge)
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
        let changed = values != lastValues
        let isNewSample = hasDrawn && changed
            && configuration.lines.count == self.configuration?.lines.count
            && configuration.capacity == self.configuration?.capacity
        if changed { sampleIndex += 1 }
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
        captionLabel.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render(newSample: false)
    }

    // MARK: - Drawing

    /// Room on the right for the head marker. A graph with nothing recorded
    /// has no marker, so its unrecorded shading runs to the edge.
    private var headInset: CGFloat {
        configuration?.glows == true && configuration?.lines.contains(where: { !$0.values.isEmpty }) == true ? 6 : 0
    }

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
        let previousCeiling = ceiling
        // The peak is scanned for only when there's no fixed top.
        ceiling = configuration.maxValue
            ?? min(GraphMath.ceiling(peak: shown.map { GraphMath.finitePeak($0) }.max() ?? 0,
                                     floor: configuration.minimumCeiling, units: configuration.axisUnits),
                   configuration.maximumCeiling)
        let rescales = hasDrawn && newSample && previousCeiling != ceiling && !reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = configuration.cornerRadius
        layer?.masksToBounds = configuration.cornerRadius > 0
        plot.frame = plotRect
        scroller.frame = CGRect(x: 0, y: 0, width: plotRect.width + 2 * step + 16, height: plotRect.height)
        scroller.rasterizationScale = window?.backingScaleFactor ?? 2
        syncSeriesLayers(count: shown.count)

        var rescaleAnimations: [(CAShapeLayer, CGPath)] = []
        // Colours resolve for this view's appearance: the data colours are
        // deeper in light mode, and re-render when it changes.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawGrid(in: plotRect, step: step, configuration: configuration)
            drawCoverage(samples: shown.map(\.count).max() ?? 0, in: plotRect, step: step, configuration: configuration)
            // Each made once: a stacked band's lower edge is the band below's trace.
            let traces = shown.map { makeTrace($0, ceiling: ceiling, height: plotRect.height) }
            for (index, values) in shown.enumerated() {
                let line = configuration.lines[index]
                let layers = series[index]
                let trace = traces[index]
                let below = configuration.stacked && index > 0 ? traces[index - 1] : nil
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
        let padding = Double(verticalPadding)
        let usable = Double(max(height - 2 * verticalPadding, 1))
        let top = max(ceiling, .leastNonzeroMagnitude)
        // A while loop over pointers, as this runs for every point of every
        // graph each sample: closures, generic min/max, a range's iterator and
        // an array's subscript each cost a call per point in a debug build.
        // Unreadable values sit on the baseline.
        let count = values.count
        var ys = [Double](repeating: padding, count: count)
        values.withUnsafeBufferPointer { valueBuffer in
            ys.withUnsafeMutableBufferPointer { yBuffer in
                guard let value = valueBuffer.baseAddress, let y = yBuffer.baseAddress else { return }
                var index = 0
                while index < count {
                    if value[index].isFinite {
                        let fraction = value[index] / top
                        y[index] = padding + usable * (fraction < 0 ? 0 : fraction > 1 ? 1 : fraction)
                    }
                    index += 1
                }
            }
        }
        return Trace(ys: ys, tangents: GraphMath.monotoneTangents(ys))
    }

    /// The line along `trace`, and the area under it (down to the baseline,
    /// or down to `below` for a stacked band).
    private func makePaths(_ trace: Trace, below: Trace?, firstX: CGFloat, step: CGFloat) -> (line: CGPath, area: CGPath) {
        let line = CGMutablePath()
        guard !trace.ys.isEmpty else { return (line, line) }
        let lastX = firstX + CGFloat(trace.ys.count - 1) * step
        line.move(to: CGPoint(x: firstX, y: CGFloat(trace.ys[0])))
        appendCurve(trace, to: line, firstX: firstX, step: step, reversed: false)

        let area = CGMutablePath()
        area.addPath(line)
        if let below, below.ys.count == trace.ys.count {
            area.addLine(to: CGPoint(x: lastX, y: CGFloat(below.ys[below.ys.count - 1])))
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
        let count = trace.ys.count
        guard count > 1, trace.tangents.count == count else { return }
        let third = step / 3
        let direction: Double = reversed ? -1 : 1
        // A while loop over pointers, as in `makeTrace`.
        trace.ys.withUnsafeBufferPointer { yBuffer in
            trace.tangents.withUnsafeBufferPointer { tangentBuffer in
                guard let ys = yBuffer.baseAddress, let tangents = tangentBuffer.baseAddress else { return }
                var offset = 0
                while offset < count - 1 {
                    let index = reversed ? count - 1 - offset : offset
                    let next = reversed ? index - 1 : index + 1
                    let x = firstX + CGFloat(index) * step
                    let nextX = firstX + CGFloat(next) * step
                    path.addCurve(
                        to: CGPoint(x: nextX, y: CGFloat(ys[next])),
                        control1: CGPoint(x: x + CGFloat(direction) * third, y: CGFloat(ys[index] + direction * tangents[index] / 3)),
                        control2: CGPoint(x: nextX - CGFloat(direction) * third, y: CGFloat(ys[next] - direction * tangents[next] / 3))
                    )
                    offset += 1
                }
            }
        }
    }

    /// The line takes the colour's shade for this appearance (deeper in light
    /// mode); its glow and the area under it keep the bright fill shade.
    private func style(_ layers: SeriesLayers, line: Line, configuration: Configuration, paths: (line: CGPath, area: CGPath)) {
        let color = line.color
        let bright = color.fillShade
        layers.line.path = paths.line
        layers.line.strokeColor = color.cgColor
        layers.line.lineWidth = configuration.lineWidth
        layers.line.lineDashPattern = line.dashed ? [4, 3] : nil
        layers.line.shadowColor = bright.cgColor
        layers.line.shadowRadius = configuration.glows ? 5 : 0
        layers.line.shadowOpacity = configuration.glows ? 0.95 : 0

        let filled = configuration.stacked || line.fill
        layers.fill.isHidden = !filled
        layers.fill.frame = scroller.bounds
        layers.fillMask.frame = layers.fill.bounds
        layers.fillMask.path = paths.area
        let top: CGFloat = configuration.stacked ? 0.70 : (configuration.glows ? 0.45 : 0.35)
        let bottom: CGFloat = configuration.stacked ? 0.30 : 0
        layers.fill.colors = [bright.withAlphaComponent(top).cgColor, bright.withAlphaComponent(bottom).cgColor]
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
        let bright = line.color.fillShade
        layers.halo.backgroundColor = bright.withAlphaComponent(0.16).cgColor
        layers.dot.backgroundColor = line.color.cgColor
        layers.dot.shadowColor = bright.cgColor
        layers.head.position = CGPoint(x: edge, y: CGFloat(last))
        layers.head.removeAnimation(forKey: "glide")

        let count = trace.ys.count
        guard animated, count > 1 else { return }
        let keyframes = (0...12).map { frame -> NSValue in
            let y = GraphMath.hermite(
                from: trace.ys[count - 2], to: last,
                startTangent: trace.tangents[count - 2], endTangent: trace.tangents[count - 1], at: Double(frame) / 12
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

    /// Runs inside `render`'s appearance block, so the colours resolve for this view.
    private func drawGrid(in plotRect: CGRect, step: CGFloat, configuration: Configuration) {
        grid.isHidden = !configuration.showsGrid
        columns.isHidden = !configuration.showsGrid
        // Light mode needs a firmer grid to hold up on a pale plot. Both stay
        // faint enough that a trace near the floor isn't lost among them.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let lineColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.065 : 0.11).cgColor
        let labelColor = NSColor.secondaryText.cgColor
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        for (label, value, y) in [(topLabel, ceiling, plotRect.height - padding), (midLabel, ceiling / 2, padding + usable / 2)] {
            let color = NSColor(cgColor: labelColor) ?? .secondaryText
            let text = NSMutableAttributedString(string: axis(value), attributes: [.font: font, .foregroundColor: color])
            if label === topLabel, let note = configuration.axisNote {
                // The note in the accent colour, so a scale that isn't fixed
                // isn't read as one that is.
                let accent = NSColor(cgColor: NSColor.controlAccentColor.cgColor) ?? .controlAccentColor
                text.append(NSAttributedString(string: "  ·  \(note)", attributes: [.font: Self.noteFont, .foregroundColor: accent]))
            }
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

// MARK: - Unrecorded stretch

/// How a graph shows a stretch with nothing recorded, in one place for the
/// live graphs (`StreamGraphView`: Performance, Overview, the process
/// inspector) and the History page's gaps (`HistoryGapStyle`): a light
/// neutral wash over the plot's tint and a faint diagonal hatch, enough to
/// tell it from a recorded quiet stretch (never drawn as zero) without
/// outweighing the data beside it, and a firmer dashed edge where recording
/// starts.
enum UnrecordedLook {
    /// Horizontal distance between the hatch's diagonals.
    static let hatchSpacing: CGFloat = 10
    static let hatchWidth: CGFloat = 0.75

    /// The window background's opacity over the plot.
    static func washOpacity(dark: Bool) -> CGFloat { dark ? 0.22 : 0.35 }
    /// The label colour's opacity in the hatch: a texture that says "nothing
    /// here", fainter than the grid's lines, while the wash and the edge
    /// mark the stretch out.
    static func hatchOpacity(dark: Bool) -> CGFloat { dark ? 0.035 : 0.03 }
    /// The label colour's opacity in the edge where recording starts.
    static func edgeOpacity(dark: Bool) -> CGFloat { dark ? 0.35 : 0.4 }
}

extension StreamGraphView {
    /// Shades the stretch before the first of `samples`, marks where
    /// recording started and captions how much is collected. A sample only
    /// moves and resizes layers here: the paths are rebuilt when the size
    /// changes, and the caption's text when its rounded figure does. Runs
    /// inside `render`'s appearance block, like `drawGrid`.
    private func drawCoverage(samples: Int, in plotRect: CGRect, step: CGFloat, configuration: Configuration) {
        // The oldest sample's x in the scroller, as in `render`. Left of it
        // nothing was recorded; with a full window it's at or past the edge.
        let start = plotRect.width + step - CGFloat(samples - 1) * step
        let filling = start > 0
        unrecorded.isHidden = !filling
        boundary.isHidden = !filling || samples == 0
        let coverage = GraphCoverage(samples: samples, capacity: configuration.capacity, interval: interval)
        defer { placeCaption(coverage, room: start - step, in: plotRect, configuration: configuration) }
        guard filling else { return }

        let size = scroller.bounds.size
        if size != hatchSize {
            hatchSize = size
            let spacing = UnrecordedLook.hatchSpacing
            let diagonals = CGMutablePath()
            var x = -size.height
            while x < size.width + spacing {
                diagonals.move(to: CGPoint(x: x, y: 0))
                diagonals.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += spacing
            }
            hatch.path = diagonals
            hatch.bounds = CGRect(x: 0, y: 0, width: size.width + spacing, height: size.height)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0.5, y: 0))
            line.addLine(to: CGPoint(x: 0.5, y: size.height))
            boundary.path = line
            boundary.bounds = CGRect(x: 0, y: 0, width: 1, height: size.height)
        }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        unrecorded.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(UnrecordedLook.washOpacity(dark: isDark)).cgColor
        hatch.strokeColor = NSColor.labelColor.withAlphaComponent(UnrecordedLook.hatchOpacity(dark: isDark)).cgColor
        boundary.strokeColor = NSColor.labelColor.withAlphaComponent(UnrecordedLook.edgeOpacity(dark: isDark)).cgColor

        unrecorded.frame = CGRect(x: 0, y: 0, width: min(start, size.width), height: size.height)
        boundary.position = CGPoint(x: start - 0.5, y: 0)
        // The scroller jumps back a step at each sample and the data is
        // redrawn a step further left, so shift the hatch with it: the
        // diagonals then slide on with the data instead of snapping back.
        let phase = (CGFloat(sampleIndex) * step).truncatingRemainder(dividingBy: UnrecordedLook.hatchSpacing)
        hatch.position = CGPoint(x: -phase, y: 0)
    }

    /// Shows the coverage caption, "40 s collected · 5 min window", at the
    /// foot of a graph with an axis: the stretch's only label, so it says
    /// what the shading is without a second line in the middle of the plot.
    /// In full or short form, whichever fits the `room` left of the first
    /// sample, and only below the axis's middle label.
    private func placeCaption(_ coverage: GraphCoverage, room: CGFloat, in plotRect: CGRect, configuration: Configuration) {
        let bottom = verticalPadding + 2
        let height: CGFloat = 15
        // The middle axis label's lower edge (see `drawGrid`).
        let clearance = plotRect.height / 2 - 14
        if coverage.caption != accessibilityCaption {
            accessibilityCaption = coverage.caption
            setAccessibilityHelp(coverage.spokenCaption)
        }
        guard configuration.axis != nil, bottom + height + 1 <= clearance,
              let full = coverage.caption, let short = coverage.shortCaption else {
            captionBadge.isHidden = true
            return
        }
        let inset: CGFloat = 5
        let text = [full, short].first { inset + captionWidth($0) + 8 + 6 <= room }
        captionBadge.isHidden = text == nil
        guard let text else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = text + (isDark ? " dark" : " light")
        let width = captionWidth(text)
        if key != shownCaption {
            shownCaption = key
            // Resolved now, for this appearance: the layer draws it later. The
            // app's secondary tone, as the system's falls under 4.5:1 here.
            let color = NSColor(cgColor: NSColor.secondaryText.cgColor) ?? .secondaryText
            captionLabel.string = NSAttributedString(string: text, attributes: [.font: Self.captionFont, .foregroundColor: color])
            captionBadge.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(isDark ? 0.7 : 0.8).cgColor
        }
        captionBadge.frame = CGRect(x: inset, y: bottom, width: width + 8, height: height)
        captionLabel.frame = CGRect(x: 4, y: 0, width: width + 1, height: 14)
    }

    private func captionWidth(_ text: String) -> CGFloat {
        if let width = captionWidths[text] { return width }
        if captionWidths.count > 64 { captionWidths.removeAll() }
        let width = ceil(NSAttributedString(string: text, attributes: [.font: Self.captionFont]).size().width)
        captionWidths[text] = width
        return width
    }
}
