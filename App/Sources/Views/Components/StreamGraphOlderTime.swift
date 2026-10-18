import AppKit
import OTMKit

/// A main graph's older time, while Squeeze older time is on
/// (`AppModel.squeeze`): each line's buckets, in the lines' order, drawn
/// to the left of its window as `TimeWarp` places them.
struct GraphSqueeze {
    var older: [[LongHistory.Bucket]]
    /// The highest of their peaks, for a scale set outside the graph.
    var peak: Double
    /// Moves on as their buckets close, so the graph redraws them only then.
    var revision: Int
    var bucketSize: Int
}

/// A squeezed graph's older time (`GraphSqueeze`), to the left of its
/// window: each line as the window draws it, over buckets placed by
/// `TimeWarp` (`SqueezedTrace`), a filled line's peaks as a faint band
/// over it, so a burst merged into a pixel still shows, the unrecorded look
/// where nothing was sampled, and a rule where each zone starts.
///
/// Laid out once per closed bucket and drawn again only when the buckets,
/// the scale, the size or the look change, so between buckets it's still:
/// rasterized, it costs nothing while the window scrolls beside it.
@MainActor
final class StreamGraphOlderTime {
    /// The older time's part of the plot, at its left.
    let layer = CALayer()
    /// Rules where each zone starts, over the whole plot's height.
    let rules = CAShapeLayer()

    /// What the lines' look depends on beyond their buckets and scale.
    struct Look {
        var padding: CGFloat
        var bloom: Double
        /// How much wider than its line the bloom's stroke is.
        var spread: CGFloat
        var emphasis: GraphEmphasis
        var isDark: Bool
        /// Moves on when the graph's colours or lines change.
        var revision: Int
    }

    private final class LineLayers {
        let fill = CAGradientLayer()
        let fillMask = CAShapeLayer()
        let band = CAShapeLayer()
        let glow = CAShapeLayer()
        let line = CAShapeLayer()

        init() {
            fill.mask = fillMask
            for stroke in [glow, line] {
                stroke.fillColor = nil
                stroke.lineCap = .round
                stroke.lineJoin = .round
            }
            band.strokeColor = nil
        }

        var layers: [CALayer] { [fill, band, glow, line] }
    }

    private struct Layout: Equatable {
        var revision: Int
        var width: CGFloat
        var span: Int
        var scale: CGFloat
        var lines: Int
        var stacked: Bool
    }

    private struct Drawing: Equatable {
        var layout: Layout
        var height: CGFloat
        var ceiling: Double
        var look: Int
        var isDark: Bool
    }

    private let wash = CAShapeLayer()
    private let hatch = CAShapeLayer()
    private let hatchMask = CAShapeLayer()
    private let boundary = CAShapeLayer()
    private var lines: [LineLayers] = []
    private var traces: [SqueezedTrace] = []
    /// A stacked graph's columns' tops, line by line, aligned on the newest.
    private var stackedTops: [[Double]] = []
    private var laidOut: Layout?
    private var drawn: Drawing?
    /// The highest figure the older time draws, for the graph's shared scale.
    private(set) var peak = 0.0
    /// How far back something is recorded, in samples, and the x it starts
    /// at, left of which nothing is; nil with nothing recorded.
    private(set) var recorded: (age: Int, x: CGFloat)?

    init() {
        layer.masksToBounds = true
        // Still between closed buckets while the window beside it scrolls.
        layer.shouldRasterize = true
        hatch.fillColor = nil
        hatch.lineWidth = UnrecordedLook.hatchWidth
        hatch.mask = hatchMask
        boundary.fillColor = nil
        boundary.lineWidth = 1
        boundary.lineDashPattern = [3, 3]
        rules.fillColor = nil
        rules.lineWidth = 0.75
        for part in [wash, hatch, boundary] { layer.addSublayer(part) }
    }

    /// Lays `squeeze` out when its buckets, the plot's width or the
    /// screen's scale have changed since; returns the highest figure it
    /// draws, which the window's scale takes in.
    func layOut(_ squeeze: GraphSqueeze, configuration: StreamGraphView.Configuration, width: CGFloat,
                scale: CGFloat) -> Double {
        let layout = Layout(revision: squeeze.revision, width: width, span: configuration.capacity, scale: scale,
                            lines: configuration.lines.count, stacked: configuration.stacked)
        guard layout != laidOut else { return peak }
        laidOut = layout
        traces = configuration.lines.indices.map { index in
            SqueezedTrace(buckets: index < squeeze.older.count ? squeeze.older[index] : [], bucketSize: squeeze.bucketSize,
                          span: configuration.capacity, width: Double(width), scale: Double(scale))
        }
        stackedTops = configuration.stacked ? GraphMath.stack(traces.map { $0.columns.map { $0.isRecorded ? $0.mean : 0 } }) : []
        peak = 0
        if configuration.stacked {
            peak = GraphMath.finitePeak(stackedTops.last ?? [])
        } else {
            for (trace, line) in zip(traces, configuration.lines) {
                for column in trace.columns where column.isRecorded {
                    peak = max(peak, line.fill ? column.peak : column.mean)
                }
            }
        }
        // How far back the line with the most behind it reaches.
        let reach = traces.min { Self.start($0) < Self.start($1) }
        if let reach, reach.columns.contains(where: \.isRecorded) {
            let start = Self.start(reach)
            let age = TimeWarp.standard.age(offset: 1 - start / Double(width)) * Double(configuration.capacity)
            recorded = (Int(age.rounded()), CGFloat(start))
        } else {
            recorded = nil
        }
        return peak
    }

    /// Where `trace`'s recorded time starts: the end of the stretch older
    /// than its oldest bucket, or the plot's left edge.
    private static func start(_ trace: SqueezedTrace) -> Double {
        guard let first = trace.gaps.first, first.from == 0 else { return 0 }
        return first.to
    }

    /// The width of `trace`'s unrecorded stretches.
    private static func unrecorded(_ trace: SqueezedTrace) -> Double {
        trace.gaps.reduce(0) { $0 + $1.to - $1.from }
    }

    /// The rules where each zone starts, across a plot `size` big.
    func drawRules(size: CGSize, color: CGColor) {
        let path = CGMutablePath()
        for edge in TimeWarp.standard.zoneEdges {
            let x = (size.width * CGFloat(1 - TimeWarp.standard.offset(age: edge))).rounded() + 0.25
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        rules.frame = CGRect(origin: .zero, size: size)
        rules.path = path
        rules.strokeColor = color
    }

    /// Draws the lines laid out, in the `size` of the plot left of its
    /// window, at `ceiling`, when anything they're drawn from has
    /// changed. Returns their paths at `previousCeiling`, for the graph to
    /// morph from as its scale changes. Runs inside the graph's appearance
    /// block, so colours resolve for its view.
    func draw(configuration: StreamGraphView.Configuration, size: CGSize, ceiling: Double, previousCeiling: Double?,
              look: Look) -> [(CAShapeLayer, CGPath)] {
        guard let layout = laidOut else { return [] }
        let drawing = Drawing(layout: layout, height: size.height, ceiling: ceiling, look: look.revision, isDark: look.isDark)
        guard drawing != drawn else { return [] }
        drawn = drawing
        layer.frame = CGRect(origin: .zero, size: size)
        layer.rasterizationScale = layout.scale
        drawUnrecorded(height: size.height, edge: layer.bounds.width, isDark: look.isDark)
        syncLines(count: configuration.lines.count)

        var morphs: [(CAShapeLayer, CGPath)] = []
        for (index, line) in configuration.lines.enumerated() where index < traces.count {
            let paths = self.paths(index, configuration: configuration, ceiling: ceiling, padding: look.padding,
                                   height: size.height)
            if let previousCeiling, previousCeiling != ceiling {
                let old = self.paths(index, configuration: configuration, ceiling: previousCeiling, padding: look.padding,
                                     height: size.height)
                let layers = lines[index]
                morphs += [(layers.line, old.line), (layers.fillMask, old.area), (layers.band, old.band)]
                if look.bloom > 0 { morphs.append((layers.glow, old.line)) }
            }
            style(lines[index], line: line, configuration: configuration, look: look, paths: paths)
        }
        return morphs
    }

    /// Shades the stretches nothing was recorded in, as the window's
    /// unrecorded stretch is, and marks where recording reaches back to.
    private func drawUnrecorded(height: CGFloat, edge: CGFloat, isDark: Bool) {
        // The line with the most behind it says what wasn't recorded.
        let gaps = traces.min { Self.unrecorded($0) < Self.unrecorded($1) }?.gaps ?? [SqueezedTrace.Gap(from: 0, to: Double(edge))]
        let shape = CGMutablePath()
        for gap in gaps where gap.to > gap.from {
            shape.addRect(CGRect(x: gap.from, y: 0, width: gap.to - gap.from, height: Double(height)))
        }
        for part in [wash, hatch, hatchMask, boundary] { part.frame = layer.bounds }
        wash.path = shape
        hatchMask.path = shape
        let spacing = UnrecordedLook.hatchSpacing
        let diagonals = CGMutablePath()
        var x = -height
        while x < edge + spacing {
            diagonals.move(to: CGPoint(x: x, y: 0))
            diagonals.addLine(to: CGPoint(x: x + height, y: height))
            x += spacing
        }
        hatch.path = diagonals
        wash.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(UnrecordedLook.washOpacity(dark: isDark)).cgColor
        hatch.strokeColor = NSColor.labelColor.withAlphaComponent(UnrecordedLook.hatchOpacity(dark: isDark)).cgColor
        boundary.strokeColor = NSColor.labelColor.withAlphaComponent(UnrecordedLook.edgeOpacity(dark: isDark)).cgColor
        // A dashed edge where recording reaches back to, as the window has where it started.
        let line = CGMutablePath()
        if let first = gaps.first, first.from == 0, first.to < Double(edge) - 0.5 {
            line.move(to: CGPoint(x: first.to.rounded() + 0.5, y: 0))
            line.addLine(to: CGPoint(x: first.to.rounded() + 0.5, y: Double(height)))
        }
        boundary.path = line
    }

    private func syncLines(count: Int) {
        while lines.count < count {
            let line = LineLayers()
            line.layers.forEach(layer.addSublayer)
            lines.append(line)
        }
        while lines.count > count {
            lines.removeLast().layers.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// A line's paths: its means, the area under them (down to the line
    /// below, stacked), and the band up to its peaks.
    private struct Paths {
        var line: CGPath
        var area: CGPath
        var band: CGPath
    }

    /// A line's `Paths` at `ceiling`.
    private func paths(_ index: Int, configuration: StreamGraphView.Configuration, ceiling: Double, padding: CGFloat,
                       height: CGFloat) -> Paths {
        let columns = traces[index].columns
        let usable = Double(max(height - 2 * padding, 1))
        let top = max(ceiling, .leastNonzeroMagnitude)
        func y(_ value: Double) -> Double {
            guard value.isFinite else { return Double(padding) }
            return Double(padding) + usable * min(max(value / top, 0), 1)
        }
        let stacked = configuration.stacked && index < stackedTops.count
        // Aligned on the newest: a line with less behind it is the tail of the longest.
        func stackedTop(_ line: Int, _ column: Int) -> Double {
            let tops = stackedTops[line]
            let offset = tops.count - columns.count
            return offset + column >= 0 && offset + column < tops.count ? tops[offset + column] : 0
        }
        let means = columns.indices.map { stacked ? y(stackedTop(index, $0)) : y(columns[$0].mean) }
        let floors = columns.indices.map { stacked && index > 0 ? y(stackedTop(index - 1, $0)) : 0 }
        let peaks = columns.map { y($0.peak) }
        let line = CGMutablePath()
        let area = CGMutablePath()
        let band = CGMutablePath()
        let showsBand = !configuration.stacked && configuration.lines[index].fill
        // One run of recorded columns at a time; an unrecorded one breaks the line.
        var start = 0
        while start < columns.count {
            guard columns[start].isRecorded else { start += 1; continue }
            var end = start
            while end + 1 < columns.count, columns[end + 1].isRecorded { end += 1 }
            let run = start...end
            line.move(to: CGPoint(x: columns[start].x, y: means[start]))
            for column in run.dropFirst() { line.addLine(to: CGPoint(x: columns[column].x, y: means[column])) }
            area.move(to: CGPoint(x: columns[start].x, y: means[start]))
            for column in run.dropFirst() { area.addLine(to: CGPoint(x: columns[column].x, y: means[column])) }
            for column in run.reversed() { area.addLine(to: CGPoint(x: columns[column].x, y: floors[column])) }
            area.closeSubpath()
            if showsBand {
                band.move(to: CGPoint(x: columns[start].x, y: peaks[start]))
                for column in run.dropFirst() { band.addLine(to: CGPoint(x: columns[column].x, y: peaks[column])) }
                for column in run.reversed() { band.addLine(to: CGPoint(x: columns[column].x, y: means[column])) }
                band.closeSubpath()
            }
            start = end + 1
        }
        return Paths(line: line, area: area, band: band)
    }

    /// As `StreamGraphView` styles the window's lines, with the band in the
    /// fill's colour, fainter than the area under the line.
    private func style(_ layers: LineLayers, line: StreamGraphView.Line, configuration: StreamGraphView.Configuration,
                       look: Look, paths: Paths) {
        let bright = line.color.fillShade
        layers.line.path = paths.line
        layers.line.strokeColor = line.color.traceShade.cgColor
        layers.line.lineWidth = line.dashed ? configuration.lineWidth : configuration.lineWidth * GraphEmphasis.traceWidth
        layers.line.lineDashPattern = line.dashed ? [4, 3] : nil
        layers.glow.isHidden = look.bloom == 0
        layers.glow.path = paths.line
        layers.glow.strokeColor = bright.withAlphaComponent(look.bloom).cgColor
        layers.glow.lineWidth = layers.line.lineWidth + look.spread
        layers.glow.lineDashPattern = layers.line.lineDashPattern

        let filled = configuration.stacked || line.fill
        let fade = CGFloat(configuration.stacked ? look.emphasis.bands : look.emphasis.fill)
        let top: CGFloat = (configuration.stacked ? 0.70 : (configuration.glows ? 0.45 : 0.35)) * fade
        let bottom: CGFloat = configuration.stacked ? 0.30 * fade : 0
        layers.fill.isHidden = !filled
        layers.fill.frame = layer.bounds
        layers.fillMask.frame = layers.fill.bounds
        layers.fillMask.path = paths.area
        layers.fill.colors = [bright.withAlphaComponent(top).cgColor, bright.withAlphaComponent(bottom).cgColor]
        layers.fill.startPoint = CGPoint(x: 0.5, y: 1)
        layers.fill.endPoint = CGPoint(x: 0.5, y: 0)
        layers.band.isHidden = !filled || configuration.stacked
        layers.band.path = paths.band
        layers.band.fillColor = bright.withAlphaComponent(top * 0.6).cgColor
    }
}
