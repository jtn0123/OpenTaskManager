import Charts
import OTMKit
import SwiftUI

/// "Trends" in a test's section of the Benchmarks workspace: a small chart
/// per figure over the saved runs, a column per run, oldest on the left.
/// Only runs that can be compared (`BenchmarkTrend`'s lines, drawn by
/// `BenchmarkComparison`'s rules) share a line: the test's colour for the set
/// with the newest run, grey, dashed then dotted, for any other. Whiskers
/// span each run's slowest to fastest repeat, and a figure whose timing is in
/// doubt is a caution triangle. A baseline, picked from the menu or by
/// clicking a run, lays its figure and spread across every chart, colours the
/// runs it can be compared with by their verdict and fades the rest. The
/// charts are static Swift Charts, built when the runs or the baseline
/// change, never per tick; hovering only shows a run's tooltip.
struct BenchmarkTrendView: View, Equatable {
    let kind: BenchmarkKind
    /// Newest first.
    let runs: [BenchmarkRun]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.runs == rhs.runs
    }

    var body: some View {
        let trend = BenchmarkTrend(runs: runs, baseline: BenchmarkWorkspace.shared.baselines[kind])
        let tint = BenchmarkLook.tint(kind)
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 10) {
            header(trend, runs: byID)
            TrendLegend(trend: trend, tint: tint, baseline: trend.baseline.flatMap { byID[$0] })
            TrendGrid(spacing: 8, multiple: Self.setSize(trend, runs: runs)) {
                ForEach(trend.figures) { figure in
                    TrendChart(figure: figure, trend: trend, runs: byID, tint: tint)
                }
            }
            Text(Self.caption(trend))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ trend: BenchmarkTrend, runs byID: [String: BenchmarkRun]) -> some View {
        let selection = Binding<String?>(get: { trend.baseline }, set: { BenchmarkWorkspace.shared.setBaseline(kind, to: $0) })
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Trends").font(.body.weight(.semibold))
            Text("\(runs.count) runs").font(.callout).foregroundStyle(.secondaryText).monospacedDigit()
            Spacer(minLength: 8)
            Picker("Baseline", selection: selection) {
                Text("None").tag(String?.none)
                if trend.lines.count == 1, let line = trend.lines.first {
                    Self.choices(line, runs: byID)
                } else {
                    ForEach(trend.lines) { line in
                        Section(line.title) { Self.choices(line, runs: byID) }
                    }
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Measure every run against one: its figure and spread are drawn across each chart")
        }
    }

    /// A line's runs, newest first, for the baseline menu.
    private static func choices(_ line: BenchmarkTrend.Line, runs: [String: BenchmarkRun]) -> some View {
        ForEach(line.runIDs.reversed(), id: \.self) { id in
            Text(runs[id].map { BenchmarkLook.when($0.date) } ?? id).tag(String?.some(id))
        }
    }

    /// How many figures share a name (the CPU's 1 worker and all workers of
    /// a workload) when every name has as many; otherwise 1.
    private static func setSize(_ trend: BenchmarkTrend, runs: [BenchmarkRun]) -> Int {
        let sizes = Set(BenchmarkFigureGroup.groups(trend.figures.map(\.id), in: runs).map(\.ids.count))
        return sizes.count == 1 ? sizes.first ?? 1 : 1
    }

    /// Under the charts: how to read them, and what a click does.
    private static func caption(_ trend: BenchmarkTrend) -> String {
        var parts: [String] = []
        if let first = trend.dates.first, let last = trend.dates.last {
            let end = Calendar.current.isDate(first, inSameDayAs: last) ? last.formatted(date: .omitted, time: .shortened)
                : BenchmarkLook.when(last)
            parts.append("A column per run, oldest on the left: \(BenchmarkLook.when(first)) to \(end).")
        }
        if trend.lines.count > 1 {
            parts.append("Only runs that can be compared share a line.")
        }
        if !trend.figures.contains(where: \.hasSpread) {
            parts.append("Each figure is measured once, so there's no spread to tell noise from change.")
        }
        parts.append(trend.baseline == nil
            ? "Hover over a run for its figures; click one, or pick it under Baseline, to measure the others against it."
            : "Runs are coloured by their verdict against the baseline, and those it can't be compared with are faded. "
                + "Click the baseline to clear it.")
        return parts.joined(separator: " ")
    }
}

/// How a trend's lines are told apart, by more than colour: the newest set
/// solid in the test's colour with circles, the others grey, dashed with
/// squares, then dotted with diamonds.
private enum TrendStyle {
    static func color(line: Int, tint: Color) -> Color {
        line == 0 ? tint : Theme.other
    }

    static func stroke(_ line: Int) -> StrokeStyle {
        switch line {
        case 0: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        case 1: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 3])
        default: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [1, 3.5])
        }
    }

    static func symbol(_ line: Int) -> BasicChartSymbolShape {
        switch line {
        case 0: .circle
        case 1: .square
        default: .diamond
        }
    }

    /// The symbol as a view, for the legend.
    @ViewBuilder static func mark(_ line: Int) -> some View {
        switch line {
        case 0: Circle().frame(width: 6, height: 6)
        case 1: Rectangle().frame(width: 6, height: 6)
        default: Rectangle().frame(width: 5, height: 5).rotationEffect(.degrees(45))
        }
    }
}

// MARK: - A figure's chart

/// One figure over the runs, its title and scale over it and, against a
/// baseline, the newest compared run's change beside them. Each run's column
/// carries a tooltip with its figures and, on a click, makes it the baseline.
private struct TrendChart: View {
    typealias Point = BenchmarkTrend.Point

    let figure: BenchmarkTrend.Figure
    let trend: BenchmarkTrend
    let runs: [String: BenchmarkRun]
    let tint: Color

    /// The x axis runs from -0.5 to this less 0.5: a column per run.
    private var columns: Double { Double(max(trend.dates.count, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Two lines rather than cut when the chart is narrow.
                Text(figure.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(figure.scaleUnit).font(.metadata).foregroundStyle(.secondaryText).fixedSize()
                Spacer(minLength: 0)
                if let compared = figure.latestCompared, let change = compared.fromBaseline {
                    Label(BenchmarkChange.formatChange(change.change ?? .nan), systemImage: BenchmarkLook.symbol(change.verdict))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(change.caveat == nil ? BenchmarkLook.color(change.verdict) : AnyShapeStyle(.secondaryText))
                        .lineLimit(1)
                        .fixedSize()
                        .help("The newest run compared with the baseline, \(BenchmarkLook.when(compared.date)): "
                            + "\(change.verdict.title.lowercased()). \(change.verdict.explanation)")
                } else {
                    // The change's room, kept so picking a baseline doesn't move the charts.
                    Label("+0.0%", systemImage: "equal.circle").font(.callout).monospacedDigit().fixedSize().hidden()
                }
            }
            // Beside a chart whose title wraps, the plots still line up.
            Spacer(minLength: 0)
            chart
                .frame(minWidth: 120, idealWidth: 150, maxWidth: .infinity)
                .frame(height: 96)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            hitAreas(plot: geometry[anchor])
                        }
                    }
                }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(tint.fillShade.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.16)))
    }

    private var chart: some View {
        Chart {
            baselineMarks
            whiskerMarks
            lineMarks
            pointMarks
        }
        .chartXScale(domain: -0.5...(columns - 0.5))
        .chartYScale(domain: figure.domain)
        .chartXAxis {
            AxisMarks(values: trend.dates.indices.map(Double.init)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.06))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: figure.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(figure.tickLabel(number))
                    }
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background(tint.opacity(0.04))
        }
    }

    // MARK: Marks

    /// The baseline's figure as a dashed rule, over a band of its spread.
    @ChartContentBuilder private var baselineMarks: some ChartContent {
        if let base = figure.baseline {
            if let low = base.low, let high = base.high {
                RectangleMark(xStart: .value("Run", -0.5), xEnd: .value("Run", columns - 0.5),
                              yStart: .value("Slowest", low), yEnd: .value("Fastest", high))
                    .foregroundStyle(Color.primary.opacity(0.07))
            }
            RuleMark(y: .value("Baseline", base.value))
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// Each run's slowest to fastest repeat, capped at both ends.
    @ChartContentBuilder private var whiskerMarks: some ChartContent {
        ForEach(figure.points.filter { $0.low != nil && $0.high != nil }) { point in
            let color = TrendStyle.color(line: point.line, tint: tint).opacity(0.6 * fade(point))
            let x = PlottableValue.value("Run", Double(point.sequence))
            RuleMark(x: x, yStart: .value("Slowest", point.low ?? point.value), yEnd: .value("Fastest", point.high ?? point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            PointMark(x: x, y: .value("Slowest", point.low ?? point.value))
                .symbol { Capsule().fill(color).frame(width: 7, height: 1.5) }
            PointMark(x: x, y: .value("Fastest", point.high ?? point.value))
                .symbol { Capsule().fill(color).frame(width: 7, height: 1.5) }
        }
    }

    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(figure.points) { point in
            LineMark(x: .value("Run", Double(point.sequence)), y: .value(figure.title, point.value), series: .value("Line", point.line))
                .foregroundStyle(TrendStyle.color(line: point.line, tint: tint).opacity(lineFade(point.line)))
                .lineStyle(TrendStyle.stroke(point.line))
        }
    }

    /// A mark per run: the line's symbol, coloured by its verdict against a
    /// baseline; a caution triangle for a figure in doubt; a ring round the baseline.
    @ChartContentBuilder private var pointMarks: some ChartContent {
        ForEach(figure.points) { point in
            let x = PlottableValue.value("Run", Double(point.sequence))
            let y = PlottableValue.value(figure.title, point.value)
            if point.caveat != nil {
                PointMark(x: x, y: y)
                    .symbol(BasicChartSymbolShape.triangle)
                    .symbolSize(48)
                    .foregroundStyle(BenchmarkLook.caution.opacity(fade(point)))
            } else {
                PointMark(x: x, y: y)
                    .symbol(TrendStyle.symbol(point.line))
                    .symbolSize(30)
                    .foregroundStyle(color(point).opacity(fade(point)))
            }
            if point.isBaseline {
                PointMark(x: x, y: y)
                    .symbol { Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5).frame(width: 14, height: 14) }
            }
        }
    }

    /// Better or worse than the baseline in their colours; otherwise the line's.
    private func color(_ point: Point) -> Color {
        if !point.isBaseline, let verdict = point.fromBaseline?.verdict {
            if verdict == .better { return BenchmarkLook.better }
            if verdict == .worse { return BenchmarkLook.worse }
        }
        return TrendStyle.color(line: point.line, tint: tint)
    }

    /// A run the baseline can't be compared with, faded while it's picked.
    private func fade(_ point: Point) -> Double {
        figure.baseline != nil && point.fromBaseline == nil ? 0.3 : 1
    }

    private func lineFade(_ line: Int) -> Double {
        if let base = figure.baseline, base.line != line { return 0.3 }
        return 1
    }

    // MARK: Hovering and clicking

    /// A clear column over each run with its tooltip; a click makes it the
    /// baseline, or clears the baseline. Nothing here reads the pointer.
    private func hitAreas(plot: CGRect) -> some View {
        let width = plot.width / columns
        return ZStack(alignment: .topLeading) {
            ForEach(figure.points) { point in
                let text = tooltip(point)
                Color.clear
                    .frame(width: max(width, 1), height: max(plot.height, 1))
                    .contentShape(Rectangle())
                    .help(text)
                    .onTapGesture { BenchmarkWorkspace.shared.setBaseline(trend.kind, to: point.isBaseline ? nil : point.runID) }
                    .accessibilityElement()
                    .accessibilityLabel(text)
                    .accessibilityAddTraits(.isButton)
                    .position(x: plot.minX + width * (Double(point.sequence) + 0.5), y: plot.midY)
            }
        }
    }

    /// The run, its figure and spread, any doubt over it, how it stands
    /// against the baseline, what it ran under, and what a click does.
    private func tooltip(_ point: Point) -> String {
        let run = runs[point.runID]
        var head = BenchmarkLook.when(point.date)
        if let title = trend.lines.first(where: { $0.id == point.line })?.title, !title.isEmpty { head += " · \(title)" }
        let spread = run?.measurement(figure.id).flatMap { measurement in
            measurement.plusMinus.map { " \($0)" + (measurement.repeats.map { " over \($0) repeats" } ?? "") }
        } ?? ""
        var lines = [head, "\(figure.title): \(figure.unit.format(point.value))\(spread)"]
        if let caveat = point.caveat { lines.append("\(caveat.title): \(caveat.brief).") }
        if point.isBaseline {
            lines.append("This run is the baseline.")
        } else if let change = point.fromBaseline {
            lines.append("\(BenchmarkChange.formatChange(change.change ?? .nan)) from the baseline: \(change.verdict.title.lowercased()). "
                + change.verdict.explanation)
        } else if let id = trend.baseline, let base = runs[id], let run, let refusal = BenchmarkComparison.refusal(base, run) {
            lines.append("Not compared with the baseline: \(refusal.summary).")
        }
        if let run, !run.conditions.isEmpty { lines.append(run.conditions.joined(separator: "; ").capitalizedFirst + ".") }
        lines.append(point.isBaseline ? "Click to clear the baseline." : "Click to make this run the baseline.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Grid

/// The charts in rows of one width: as many to a row as fit at `minimum`,
/// spread evenly over the rows (four go two and two, not three and one),
/// and when the figures come in sets (the CPU's 1 worker and all workers of
/// each workload) whole sets to a row, so every row reads the same way. A
/// short last row keeps the others' width; a row is as tall as its tallest
/// chart, a title that wraps included.
private struct TrendGrid: Layout {
    var spacing: CGFloat
    /// Figures per set.
    var multiple: Int
    var minimum: CGFloat = 220

    private struct Row {
        var items: Range<Int>
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum * CGFloat(perRow(count: subviews.count, width: .infinity))
        let rows = rows(subviews: subviews, width: width)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let itemWidth = itemWidth(count: subviews.count, width: bounds.width)
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: itemWidth, height: row.height))
                x += itemWidth + spacing
            }
            y += row.height + spacing
        }
    }

    /// Charts to a row: whole sets while one fits, otherwise the fewest rows
    /// that hold them, filled evenly.
    private func perRow(count: Int, width: CGFloat) -> Int {
        let fitting = GridMath.columnCount(count: count, width: width, minimum: minimum, spacing: spacing)
        if multiple > 1, fitting >= multiple { return fitting - fitting % multiple }
        let rows = (count + fitting - 1) / max(fitting, 1)
        return max((count + rows - 1) / max(rows, 1), 1)
    }

    private func itemWidth(count: Int, width: CGFloat) -> CGFloat {
        let columns = CGFloat(perRow(count: count, width: width))
        return max((width - spacing * (columns - 1)) / columns, 0)
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        let perRow = perRow(count: subviews.count, width: width)
        let itemWidth = itemWidth(count: subviews.count, width: width)
        return stride(from: 0, to: subviews.count, by: perRow).map { start in
            let items = start..<min(start + perRow, subviews.count)
            let height = items.map { subviews[$0].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            return Row(items: items, height: height)
        }
    }
}

// MARK: - Legend

/// What the marks mean: each line (when there's more than one), the
/// whiskers, a figure in doubt, and the baseline.
private struct TrendLegend: View {
    let trend: BenchmarkTrend
    let tint: Color
    let baseline: BenchmarkRun?

    var body: some View {
        let spread = trend.figures.contains(where: \.hasSpread)
        let caveat = trend.figures.lazy.flatMap(\.points).compactMap(\.caveat).first
        if trend.lines.count > 1 || spread || caveat != nil || baseline != nil {
            LegendFlow {
                if trend.lines.count > 1 {
                    ForEach(trend.lines) { line in
                        TrendLegendItem(text: line.title) { TrendLineSample(line: line.id, tint: tint) }
                            .help("\(line.runIDs.count) \(line.runIDs.count == 1 ? "run" : "runs") that can be compared with each other")
                    }
                }
                if spread {
                    TrendLegendItem(text: "Slowest to fastest repeat") { WhiskerSample(color: tint) }
                }
                if let caveat {
                    TrendLegendItem(text: caveat.title) {
                        Image(systemName: "triangle.fill").imageScale(.small).foregroundStyle(BenchmarkLook.caution)
                    }
                    .help(caveat.explanation)
                }
                if let baseline {
                    TrendLegendItem(text: "Baseline, \(BenchmarkLook.when(baseline.date))") { BaselineSample() }
                        .help("The baseline's figure is the dashed line, its spread the shaded band")
                }
            }
            .font(.callout)
        }
    }
}

/// The legend's items from the leading edge, each at its own width, onto
/// another line when the next doesn't fit.
private struct LegendFlow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(subviews: subviews, width: bounds.width).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

private struct TrendLegendItem<Mark: View>: View {
    let text: String
    @ViewBuilder var mark: Mark

    var body: some View {
        HStack(spacing: 5) {
            mark
            Text(text).foregroundStyle(.secondaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A line as it's stroked, with its symbol.
private struct TrendLineSample: View {
    let line: Int
    let tint: Color

    var body: some View {
        let color = TrendStyle.color(line: line, tint: tint)
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 5))
                path.addLine(to: CGPoint(x: 21, y: 5))
            }
            .stroke(color, style: TrendStyle.stroke(line))
            TrendStyle.mark(line).foregroundStyle(color)
        }
        .frame(width: 22, height: 10)
    }
}

private struct WhiskerSample: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 4, y: 1))
            path.addLine(to: CGPoint(x: 4, y: 11))
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 7, y: 1))
            path.move(to: CGPoint(x: 1, y: 11))
            path.addLine(to: CGPoint(x: 7, y: 11))
        }
        .stroke(color.opacity(0.6), lineWidth: 1.5)
        .frame(width: 8, height: 12)
    }
}

private struct BaselineSample: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 6))
                path.addLine(to: CGPoint(x: 22, y: 6))
            }
            .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5).frame(width: 11, height: 11)
        }
        .frame(width: 22, height: 12)
    }
}
