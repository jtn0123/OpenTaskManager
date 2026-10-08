import Charts
import OTMKit
import SwiftUI

/// One line on a history chart.
struct HistoryLine: Identifiable {
    enum Summary {
        case average
        case maximum
    }

    /// How the line is stroked, on the chart and in its legend's sample, so
    /// two lines on a chart differ by more than their colour.
    enum Stroke: CaseIterable {
        case solid
        case dashed
        case dotted
        case dashDot
        case longDash

        var style: StrokeStyle {
            switch self {
            case .solid: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            case .dashed: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [4, 3])
            // Zero-length dashes with round caps draw as dots.
            case .dotted: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0, 3.6])
            case .dashDot: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [6, 3, 0, 3])
            case .longDash: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [10, 4])
            }
        }

        /// Whether the line's ends at a break get a dot: not for a plain
        /// dashed line, whose ends a dot would only clutter.
        var marksBreaks: Bool { self != .dashed }
    }

    var id: String { name }
    let name: String
    /// The legend's name for the line's figure, when the line's own name
    /// doesn't say what it sums up: CPU's "Window average" and "Window peak".
    var legend: String?
    let color: Color
    let value: (HistoryValues) -> Double?
    var fill = true
    var stroke = Stroke.solid
    /// How the legend sums the line up over the range.
    var summary = Summary.average
    /// What the line plots, for the legend's tooltip: "the share of the
    /// whole CPU in use", which it follows with the stretch each point covers.
    let meaning: String
    /// A sentence more for the tooltip, after the stretch.
    var note: String?
}

/// A history chart: its lines and how its axis is scaled and labelled.
struct HistoryChartSpec: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    let tint: Color
    let lines: [HistoryLine]
    let format: (Double) -> String
    /// A fixed top for the scale; nil scales to the data.
    var ceiling: Double?
    /// An auto-scaled axis never zooms in further than this.
    var floor = 0.0
    var units = GraphMath.AxisUnits.plain
    /// Takes the CPU graphs' Auto / 100% choice (`CPUGraphScale`): on
    /// Auto it fits its data, in place of `ceiling`.
    var followsCPUScale = false

    /// The charts worth drawing for these points: GPU, power and temperature
    /// only when the Mac reported them.
    static func all(for points: [HistoryPoint]) -> [HistoryChartSpec] {
        func has(_ value: (HistoryValues) -> Double?) -> Bool { points.contains { value($0.values) != nil } }
        var specs = [
            HistoryChartSpec(title: "CPU", symbol: "cpu", tint: Theme.cpu, lines: [
                HistoryLine(name: "Average", legend: "Window average", color: Theme.cpu, value: { $0.cpu },
                            meaning: "the share of the whole CPU in use"),
                HistoryLine(name: "Peak", legend: "Window peak", color: Theme.cpu.opacity(0.7), value: { $0.cpuPeak }, fill: false,
                            stroke: .dashed, summary: .maximum,
                            meaning: "the share of the whole CPU in use at the busiest single update"),
            ], format: { Format.percent($0) }, ceiling: 1, followsCPUScale: true),
            HistoryChartSpec(title: "Memory", symbol: "memorychip", tint: Theme.memory, lines: [
                HistoryLine(name: "Used", color: Theme.memory, value: { $0.memory },
                            meaning: "memory used by apps, wired down or compressed, as a share of all memory"),
                HistoryLine(name: "Pressure", color: Theme.wired, value: { $0.memoryPressure }, fill: false, stroke: .dotted,
                            meaning: "the share of memory macOS doesn't count as available",
                            note: "As it climbs, macOS compresses and swaps more."),
            ], format: { Format.percent($0) }, ceiling: 1),
        ]
        if has({ $0.gpu }) {
            specs.append(HistoryChartSpec(title: "GPU", symbol: "square.stack.3d.up", tint: Theme.gpu, lines: [
                HistoryLine(name: "Load", color: Theme.gpu, value: { $0.gpu }, meaning: "the busiest GPU's load"),
            ], format: { Format.percent($0) }, ceiling: 1))
        }
        if has({ $0.systemWatts }) {
            specs.append(HistoryChartSpec(title: "Power", symbol: "bolt.fill", tint: Theme.power, lines: [
                HistoryLine(name: "System", color: Theme.power, value: { $0.systemWatts }, meaning: "the whole Mac's power draw"),
                HistoryLine(name: "CPU", color: Theme.cpu, value: { $0.cpuWatts }, fill: false, meaning: "the CPU's part of that draw"),
                HistoryLine(name: "GPU", color: Theme.gpu, value: { $0.gpuWatts }, fill: false, stroke: .dotted,
                            meaning: "the GPU's part of that draw"),
            ], format: Format.watts, floor: 10))
        }
        specs.append(HistoryChartSpec(title: "Disk", symbol: "internaldrive", tint: Theme.disk, lines: [
            HistoryLine(name: "Read", color: Theme.disk, value: { $0.diskRead }, meaning: "data read from every disk per second"),
            HistoryLine(name: "Write", color: Theme.diskSecondary, value: { $0.diskWrite }, fill: false,
                        meaning: "data written to every disk per second"),
        ], format: Format.bytesPerSecond, floor: 1_048_576, units: .binaryBytes))
        specs.append(HistoryChartSpec(title: "Network", symbol: "network", tint: Theme.network, lines: [
            HistoryLine(name: "Received", color: Theme.network, value: { $0.networkIn },
                        meaning: "data received per second over the network links that are up"),
            HistoryLine(name: "Sent", color: Theme.networkSecondary, value: { $0.networkOut }, fill: false,
                        meaning: "data sent per second over the network links that are up"),
        ], format: Format.bitsPerSecond, floor: 125_000, units: .bits))
        if has({ $0.chipCelsius }) {
            specs.append(HistoryChartSpec(title: "Temperature", symbol: "thermometer.medium", tint: Theme.thermal, lines: [
                HistoryLine(name: "Chip", color: Theme.thermal, value: { $0.chipCelsius }, meaning: "the hottest sensor on the chip's die"),
            ], format: Format.celsius, floor: 60))
        }
        return specs
    }

    /// Top of the scale for these points. A chart that follows the CPU
    /// scale, on Auto, takes the round bound that fits them (`AutoScale`):
    /// it only changes when a new peak arrives or the old one leaves the range.
    func top(for points: [HistoryPoint], cpuScale: CPUGraphScale = .full) -> Double {
        if autoScales(cpuScale) { return AutoScale.bound(for: peak(in: points)) }
        if let ceiling { return ceiling }
        return GraphMath.ceiling(peak: peak(in: points), floor: floor, units: units)
    }

    /// Whether the scale is fitted by `AutoScale`, and labelled so.
    func autoScales(_ cpuScale: CPUGraphScale) -> Bool {
        followsCPUScale && cpuScale == .auto
    }

    private func peak(in points: [HistoryPoint]) -> Double {
        points.reduce(0.0) { result, point in
            lines.reduce(result) { max($0, $1.value(point.values) ?? 0) }
        }
    }

    /// The legend's figure for a line over the time shown: its average, or
    /// for a peak its highest.
    func summary(of line: HistoryLine, in points: [HistoryPoint]) -> String {
        let values = points.compactMap { line.value($0.values) }
        guard !values.isEmpty else { return "—" }
        switch line.summary {
        case .average: return format(values.reduce(0, +) / Double(values.count))
        case .maximum: return format(values.max() ?? 0)
        }
    }

    /// What the legend's figures sum up, when every line's figure is an
    /// average and its name doesn't say so: "Window average", once before them.
    var legendLead: String? {
        lines.allSatisfy { $0.legend == nil && $0.summary == .average } ? "Window average" : nil
    }

    /// The legend's tooltip for a line, whose points each cover `bucket`
    /// seconds: what it plots, and what the figure beside it sums up.
    /// "Peak: the share of the whole CPU in use at the busiest single update
    /// within each 10-second record. Window peak: the highest over the
    /// window shown."
    static func definition(of line: HistoryLine, bucket: TimeInterval) -> String {
        let stretch = "each \(HistoryInterval.adjective(bucket)) point"
        let plotted = switch line.summary {
        case .average: "\(line.name): \(line.meaning), averaged over \(stretch)."
        case .maximum: "\(line.name): \(line.meaning) within \(stretch)."
        }
        let figure = switch line.summary {
        case .average: "Window average: its average over the window shown, counting recorded time only; gaps are left out."
        case .maximum: "Window peak: the highest over the window shown."
        }
        return [plotted, line.note, figure].compactMap { $0 }.joined(separator: " ")
    }
}

/// A legend's sample of a line as its chart draws it: the stroke, solid
/// with its glow, dashed or dotted, over a sliver of the fill when the line
/// has one.
struct HistoryLineSample: View {
    let line: HistoryLine

    var body: some View {
        Canvas { context, size in
            let y = line.fill ? 3.5 : size.height / 2
            if line.fill {
                let area = CGRect(x: 0, y: y, width: size.width, height: size.height - y)
                context.fill(Path(roundedRect: area, cornerRadius: 1.5),
                             with: .linearGradient(Gradient(colors: [line.color.opacity(0.42), line.color.opacity(0.03)]),
                                                   startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: size.height)))
            }
            var path = Path()
            path.move(to: CGPoint(x: 1.5, y: y))
            path.addLine(to: CGPoint(x: size.width - 1.5, y: y))
            if line.stroke == .solid {
                context.stroke(path, with: .color(line.color.opacity(0.22)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            context.stroke(path, with: .color(line.color), style: line.stroke.style)
        }
        .frame(width: 18, height: 11)
        .accessibilityHidden(true)
    }
}

/// One history chart in a card. It takes only values, never the scrubber's
/// moments, so moving the pointer redraws the markers and not the chart.
struct HistoryChartCard: View {
    let spec: HistoryChartSpec
    let points: [HistoryPoint]
    /// Seconds each point covers, for the legend's tooltips.
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    /// When the recording began; the chart dims the time before it.
    let earliest: Date?
    /// The stretches with nothing recorded, and how they're drawn.
    let gaps: HistoryGapMarks
    /// Where the time axis is labelled.
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CPUGraphScale.key) private var cpuScale = CPUGraphScale.auto

    private var title: some View {
        Label(spec.title, systemImage: spec.symbol)
            .font(.headline)
            .foregroundStyle(spec.tint)
            .fixedSize()
    }

    /// Each line's sample, stroked as it's drawn, its name and its figure
    /// over the window shown ("Window peak 48%", or after a "Window average"
    /// lead, "Used 60%"); what both mean is in the tooltip.
    @ViewBuilder private var legend: some View {
        if let lead = spec.legendLead {
            Text(lead)
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .fixedSize()
                .help("The figures beside each line are its average over the window shown, counting recorded time only.")
        }
        ForEach(spec.lines) { line in
            HStack(spacing: 5) {
                HistoryLineSample(line: line)
                Text(line.legend ?? line.name).foregroundStyle(.secondaryText)
                Text(spec.summary(of: line, in: points)).monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
            .contentShape(Rectangle())
            .help(HistoryChartSpec.definition(of: line, bucket: bucket))
        }
    }

    /// The top and middle axis labels; an auto scale says so after the top.
    private func axisLabels(top: Double) -> [String] {
        guard spec.autoScales(cpuScale) else { return [spec.format(top), spec.format(top / 2)] }
        return [CPUGraphScale.axisLabel(top) + " · " + CPUGraphScale.autoNote, CPUGraphScale.axisLabel(top / 2)]
    }

    var body: some View {
        let top = spec.top(for: points, cpuScale: cpuScale)
        Card(tint: spec.tint) {
            // The legend sits beside the title while it fits, then under it,
            // then one line per series in a narrow window: never squeezed.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    title
                    Spacer(minLength: 0)
                    legend
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    HStack(spacing: 14) { legend }
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    legend
                }
            }
            chart(top: top)
                .frame(height: 130)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            HistoryPlotOverlay(plot: geometry[anchor], domain: domain, points: points, gaps: gaps,
                                               scrubber: scrubber, labels: axisLabels(top: top), tint: spec.tint)
                        }
                    }
                }
        }
    }

    private func chart(top: Double) -> some View {
        let wash = HistoryGapStyle.wash(dark: colorScheme == .dark)
        return Chart {
            if let earliest, earliest > domain.lowerBound {
                RectangleMark(xStart: .value("Time", domain.lowerBound), xEnd: .value("Time", min(earliest, domain.upperBound)))
                    .foregroundStyle(.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
                    // A caption at its foot, like a live graph's, rather than a label over the middle of the plot.
                    .annotation(position: .overlay, alignment: .bottomLeading) {
                        if earliest.timeIntervalSince(domain.lowerBound) > domain.upperBound.timeIntervalSince(domain.lowerBound) / 5 {
                            Text("Not recorded yet").font(.metadata).foregroundStyle(.secondaryText).padding([.leading, .bottom], 6)
                        }
                    }
            }
            // Fills first, then each gap's wash with a fade either side, so a
            // fill dissolves into a gap instead of ending in an edge that
            // reads as the value dropping; the lines go over both. A line and
            // its fill also break where a reading is missing (`runs`), rather
            // than bridge it; a lone point has its dot, below, and no fill.
            ForEach(spec.lines.filter(\.fill)) { line in
                let runs = HistoryPoint.runs(points, value: line.value)
                let lone = HistoryPoint.lone(runs)
                ForEach(points.indices, id: \.self) { index in
                    if let run = runs[index], !lone.contains(run), let value = line.value(points[index].values) {
                        AreaMark(x: .value("Time", points[index].time), y: .value(line.name, min(value, top)),
                                 series: .value("Series", "\(line.name) \(run)"), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [line.color.opacity(0.42), line.color.opacity(0.03)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            ForEach(gaps.shades.indices, id: \.self) { index in
                let shade = gaps.shades[index]
                RectangleMark(xStart: .value("Time", shade.start), xEnd: .value("Time", shade.end))
                    .foregroundStyle(Self.style(of: shade.kind, wash: wash))
            }
            ForEach(spec.lines) { line in
                let runs = HistoryPoint.runs(points, value: line.value)
                ForEach(points.indices, id: \.self) { index in
                    if let run = runs[index], let value = line.value(points[index].values) {
                        let series = "\(line.name) \(run)"
                        // A wide faint stroke under a solid line, for the glow.
                        if line.stroke == .solid {
                            LineMark(x: .value("Time", points[index].time), y: .value(line.name, min(value, top)),
                                     series: .value("Series", series + " glow"))
                                .foregroundStyle(line.color.opacity(0.22))
                                .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("Time", points[index].time), y: .value(line.name, min(value, top)),
                                 series: .value("Series", series))
                            .foregroundStyle(line.color)
                            .lineStyle(line.stroke.style)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            ForEach(spec.lines) { line in
                ForEach(dots(on: line), id: \.self) { index in
                    if let value = line.value(points[index].values) {
                        PointMark(x: .value("Time", points[index].time), y: .value(line.name, min(value, top)))
                            .foregroundStyle(line.color)
                            .symbolSize(18)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            // Faint, as on the live graphs, so a low line isn't lost among them.
            AxisMarks(values: [0, top / 2, top]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.055))
                // Centred under its line, as `GraphMath.timeTicks` spaces them: a
                // label hanging right of its tick ran past the plot's end and was cut.
                AxisValueLabel(format: timeLabels, anchor: .top).font(.system(size: 11)).foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background(LinearGradient(colors: [spec.tint.opacity(0.10), spec.tint.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
                .overlay { HistoryGapHatch(gaps: gaps.drawn, domain: domain) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The points (by index) that get a dot on `line`: where it breaks off,
    /// at a gap or a missing reading, and where it picks up, so the break
    /// reads as a pause; and on every line, dashed too, a lone point.
    private func dots(on line: HistoryLine) -> [Int] {
        let runs = HistoryPoint.runs(points, value: line.value)
        let lone = HistoryPoint.lone(runs)
        let ends = line.stroke.marksBreaks ? gaps.borders + HistoryPoint.breaks(points, runs: runs) : []
        let alone = lone.isEmpty ? [] : points.indices.filter { runs[$0].map(lone.contains) ?? false }
        return Set(ends + alone).filter { $0 < points.count }.sorted()
    }

    /// A gap's wash, or a fade from nothing into it or out of it.
    private static func style(of kind: HistoryGap.Shade.Kind, wash: Color) -> LinearGradient {
        let colors: [Color] = switch kind {
        case .fadeIn: [wash.opacity(0), wash]
        case .gap: [wash, wash]
        case .fadeOut: [wash, wash.opacity(0)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// Where moments sit on the History page's time axes, and how they read.
enum HistoryMoment {
    /// The time at `x` across a plot `width` wide spanning `domain`.
    static func time(at x: CGFloat, width: CGFloat, domain: ClosedRange<Date>) -> Date {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return domain.lowerBound.addingTimeInterval(span * min(max(x / max(width, 1), 0), 1))
    }

    /// The recorded moment nearest `x` across a plot `width` wide spanning
    /// `domain`, so a pin always lands on a point with figures behind it.
    static func at(x: CGFloat, width: CGFloat, domain: ClosedRange<Date>, points: [HistoryPoint]) -> Date? {
        guard width > 0 else { return nil }
        let time = time(at: x, width: width, domain: domain)
        return HistoryPoint.nearest(to: time, in: points)?.time ?? time
    }

    /// How far across a plot `width` wide `time` sits.
    static func x(of time: Date, width: CGFloat, domain: ClosedRange<Date>) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return width * time.timeIntervalSince(domain.lowerBound) / max(span, 1)
    }

    /// The stretch a point's figures cover, as their label puts it: "10-second"
    /// (average, peak), "4-minute" for coarser points, "1-second" in a spike capture.
    static func scope(_ bucket: TimeInterval) -> String {
        HistoryInterval.adjective(bucket)
    }

    /// "7:03:20 AM", with seconds while points are that fine and the day
    /// when it isn't today.
    static func label(_ time: Date, bucket: TimeInterval) -> String {
        var style: Date.FormatStyle = bucket < 60 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
        if !Calendar.current.isDateInToday(time) { style = style.weekday(.abbreviated) }
        return time.formatted(style)
    }
}

/// Axis labels inside the plot, the target where hovering previews a moment
/// (or names the gap under the pointer) and a click or drag pins one, and
/// the moment markers.
struct HistoryPlotOverlay: View {
    let plot: CGRect
    let domain: ClosedRange<Date>
    let points: [HistoryPoint]
    let gaps: HistoryGapMarks
    let scrubber: HistoryScrubber
    /// Top and middle of the scale.
    let labels: [String]
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index])
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .offset(x: plot.minX + 6, y: plot.minY + 3 + plot.height / 2 * CGFloat(index))
            }
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: plot.width, height: plot.height)
                .offset(x: plot.minX, y: plot.minY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hover(at: location.x)
                    case .ended: scrubber.hover(nil)
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { scrubber.pin(moment(at: $0.location.x)) })
            HistoryMarkers(scrubber: scrubber, plot: plot, domain: domain, gaps: gaps, tint: tint)
        }
    }

    /// Previews the moment under the pointer, or names the gap it's over.
    private func hover(at x: CGFloat) {
        if let gap = gaps.gap(at: HistoryMoment.time(at: x, width: plot.width, domain: domain)) {
            scrubber.hover(nil, gap: gap)
        } else {
            scrubber.hover(moment(at: x))
        }
    }

    private func moment(at x: CGFloat) -> Date? {
        HistoryMoment.at(x: x, width: plot.width, domain: domain, points: points)
    }
}

/// The moments on a chart, each marked its own way: where playback is, a
/// solid line in the replay's tint under a notch; a pinned moment, a line in
/// the chart's tint under a bead, as the rail's handle sits over it; a
/// moment the pointer previews, a fainter dashed line; and a gap the pointer
/// is over, edged. The session being marked or picked is shaded. It alone
/// reads the scrubber, so it's the only part of a chart that redraws as the
/// pointer moves or playback steps.
private struct HistoryMarkers: View {
    let scrubber: HistoryScrubber
    let plot: CGRect
    let domain: ClosedRange<Date>
    let gaps: HistoryGapMarks
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let marked = scrubber.marked {
                band(marked.start, marked.end)
            }
            if let compare = scrubber.compare {
                if let b = compare.resolvedB, compare.a != nil {
                    compared(.b, b)
                }
                if let a = compare.a {
                    compared(.a, a)
                }
            }
            if let gap = scrubber.hoveredGap ?? scrubber.selectedGap {
                edges(of: gaps.drawn(gap))
            }
            if let playhead = scrubber.playhead, domain.contains(playhead) {
                let x = x(of: playhead)
                Rectangle()
                    .fill(HistorySessionStyle.tint)
                    .frame(width: 2, height: plot.height)
                    .offset(x: x - 1, y: plot.minY)
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 10, y: 0))
                    path.addLine(to: CGPoint(x: 5, y: 7))
                    path.closeSubpath()
                }
                .fill(HistorySessionStyle.tint)
                .frame(width: 10, height: 7)
                .offset(x: x - 5, y: plot.minY - 3)
            }
            if let pinned = scrubber.pinned, domain.contains(pinned) {
                let x = x(of: pinned)
                Rectangle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2, height: plot.height)
                    .offset(x: x - 1, y: plot.minY)
                Circle()
                    .fill(tint)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .offset(x: x - 4.5, y: plot.minY - 4.5)
            }
            if let hovered = scrubber.hovered, hovered != scrubber.pinned, hovered != scrubber.playhead, domain.contains(hovered) {
                Path { path in
                    path.move(to: CGPoint(x: 0.5, y: 0))
                    path.addLine(to: CGPoint(x: 0.5, y: plot.height))
                }
                .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 1, height: plot.height)
                .offset(x: x(of: hovered) - 0.5, y: plot.minY)
            }
        }
        .allowsHitTesting(false)
    }

    /// A session's stretch, cut to the range shown, with a line at each end
    /// inside it; one still being marked has only its start.
    @ViewBuilder private func band(_ start: Date, _ end: Date?) -> some View {
        let tint = HistorySessionStyle.tint
        if start <= domain.upperBound, (end ?? start) >= domain.lowerBound {
            let lower = x(of: max(start, domain.lowerBound))
            let upper = x(of: min(end ?? start, domain.upperBound))
            Rectangle()
                .fill(tint.opacity(0.10))
                .frame(width: max(upper - lower, 0), height: plot.height)
                .offset(x: lower, y: plot.minY)
            ForEach([start, end].compactMap { $0 }.filter { domain.contains($0) }, id: \.self) { edge in
                Rectangle()
                    .fill(tint.opacity(0.7))
                    .frame(width: 1, height: plot.height)
                    .offset(x: x(of: edge) - 0.5, y: plot.minY)
            }
        }
    }

    /// A stretch being compared, tinted and lettered at its top left.
    @ViewBuilder private func compared(_ side: HistoryCompareDraft.Side, _ range: ClosedRange<Date>) -> some View {
        if range.lowerBound <= domain.upperBound, range.upperBound >= domain.lowerBound {
            let tint = HistoryCompareDraft.tint(side)
            let lower = x(of: max(range.lowerBound, domain.lowerBound))
            let upper = max(x(of: min(range.upperBound, domain.upperBound)), lower + 1)
            Rectangle()
                .fill(tint.opacity(0.12))
                .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.6)).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(tint.opacity(0.6)).frame(width: 1) }
                .frame(width: upper - lower, height: plot.height)
                .offset(x: lower, y: plot.minY)
            Text(side == .a ? "A" : "B")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(tint))
                // At the top, where the plots are mostly empty, and at the
                // stretch's end, clear of the axis labels down the left.
                .offset(x: min(max(upper - 16, lower + 2), plot.maxX - 16), y: plot.minY + 2)
        }
    }

    /// The gap under the pointer, darkened a touch between dashed edges.
    @ViewBuilder private func edges(of gap: HistoryGap) -> some View {
        if gap.start <= domain.upperBound, gap.end >= domain.lowerBound {
            let lower = x(of: max(gap.start, domain.lowerBound))
            let upper = max(x(of: min(gap.end, domain.upperBound)), lower + 1)
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(width: upper - lower, height: plot.height)
                .offset(x: lower, y: plot.minY)
            Path { path in
                for edge in [lower, upper] {
                    path.move(to: CGPoint(x: edge, y: plot.minY))
                    path.addLine(to: CGPoint(x: edge, y: plot.maxY))
                }
            }
            .stroke(HistoryGapStyle.edge(dark: colorScheme == .dark), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func x(of time: Date) -> CGFloat {
        plot.minX + HistoryMoment.x(of: time, width: plot.width, domain: domain)
    }
}
