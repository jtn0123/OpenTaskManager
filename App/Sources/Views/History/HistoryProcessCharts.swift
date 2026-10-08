import Charts
import OTMKit
import SwiftUI

/// One of a process's charts: its lines (reading `HistoryProcessKey`'s
/// figures), each with the legend's figure over the range, and how its
/// axis is scaled and labelled.
struct HistoryProcessChart: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    let tint: Color
    let lines: [HistoryLine]
    /// Each line's figure over the range, from the lifetime's summary.
    let figures: [String]
    /// What the figures sum up: "Window average", "Window peak".
    let lead: String
    let format: (Double) -> String
    var floor = 0.0
    var units = GraphMath.AxisUnits.plain

    func top(for points: [HistoryPoint]) -> Double {
        let peak = points.reduce(0.0) { result, point in lines.reduce(result) { max($0, $1.value(point.values) ?? 0) } }
        return GraphMath.ceiling(peak: peak, floor: floor, units: units)
    }
}

/// The picked process's charts under the Processes card: CPU, average and
/// peak, on the page's CPU scale; memory (its footprint, or resident memory
/// for another user's process, as the Processes page shows); and disk read
/// and write, which macOS gives only for your own processes.
struct HistoryProcessCharts: View {
    @Environment(AppModel.self) private var model
    let track: HistoryProcessStore.Track
    /// The page's points, which a click on a chart snaps to.
    let points: [HistoryPoint]
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    let gaps: HistoryGapMarks
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber

    var body: some View {
        ForEach(charts) { chart in
            HistoryProcessChartCard(chart: chart, track: track, pagePoints: points, bucket: bucket, domain: domain, gaps: gaps,
                                    ticks: ticks, timeLabels: timeLabels, scrubber: scrubber)
        }
        if track.lifetime.isRestricted {
            NoticeStrip(title: "Disk", symbol: "internaldrive", color: Theme.disk,
                        text: "Not given for other users' and system processes",
                        help: "macOS gives another user's or a system process's CPU and memory, not its disk use, so none was recorded.",
                        compact: true)
        }
    }

    private var charts: [HistoryProcessChart] {
        let scale = model.cpuScale
        let summary = track.match.summary
        let memoryName = track.lifetime.isRestricted ? "Resident" : "Footprint"
        func show(_ value: Double?, _ format: (Double) -> String) -> String { value.map(format) ?? "—" }
        var charts = [
            HistoryProcessChart(title: "CPU", symbol: "cpu", tint: Theme.cpu, lines: [
                HistoryLine(name: "Average", color: Theme.cpu, value: { $0.hardware[HistoryProcessKey.cpu].map(scale.value) },
                            meaning: "its CPU, on the page's scale"),
                HistoryLine(name: "Peak", color: Theme.cpu.opacity(0.7), value: { $0.hardware[HistoryProcessKey.cpuPeak].map(scale.value) },
                            fill: false, stroke: .dashed, summary: .maximum, meaning: "its busiest single record's CPU"),
            ], figures: [show(summary.averageCPU, scale.format), show(summary.peakCPU, scale.format)], lead: "Over the range",
               format: { Format.fixed($0, $0 < 10 ? 1 : 0) + "%" }, floor: scale.relativeToSystem ? 2 : 10),
            HistoryProcessChart(title: "Memory", symbol: "memorychip", tint: Theme.memory, lines: [
                HistoryLine(name: memoryName, legend: "Peak", color: Theme.memory, value: { $0.hardware[HistoryProcessKey.memory] },
                            summary: .maximum,
                            meaning: track.lifetime.isRestricted ? "its resident memory" : "its memory footprint, as the Memory column shows"),
            ], figures: [summary.peakMemory.map { Format.bytes($0) } ?? "—"], lead: "Over the range",
               format: { Format.bytes(UInt64(max($0, 0))) }, floor: 1_048_576, units: .binaryBytes),
        ]
        if !track.lifetime.isRestricted {
            charts.append(HistoryProcessChart(title: "Disk", symbol: "internaldrive", tint: Theme.disk, lines: [
                HistoryLine(name: "Read", color: Theme.disk, value: { $0.hardware[HistoryProcessKey.diskRead] },
                            meaning: "data it read per second"),
                HistoryLine(name: "Write", color: Theme.diskSecondary, value: { $0.hardware[HistoryProcessKey.diskWrite] }, fill: false,
                            meaning: "data it wrote per second"),
            ], figures: [show(summary.averageDiskRead, Format.bytesPerSecond), show(summary.averageDiskWrite, Format.bytesPerSecond)],
               lead: "Average", format: Format.bytesPerSecond, floor: 1_048_576, units: .binaryBytes))
        }
        return charts
    }
}

/// One process chart in a card, drawn as the page's charts are, plus what a
/// process's lifetime adds: the stretches it ran idle (its figures not
/// stored) in a tinted wash, never a line at zero; before it started and
/// after it ended dimmed; and where it wasn't watched (before History first
/// saw it, or after it stopped watching it) hatched like a gap. A click or
/// drag pins the page's moments, as on the charts above.
private struct HistoryProcessChartCard: View {
    let chart: HistoryProcessChart
    let track: HistoryProcessStore.Track
    let pagePoints: [HistoryPoint]
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    let gaps: HistoryGapMarks
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let points = track.points
        let top = chart.top(for: points)
        Card(tint: chart.tint) {
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
            }
            plot(points, top: top)
                .frame(height: 110)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            HistoryPlotOverlay(plot: geometry[anchor], domain: domain, points: pagePoints, gaps: gaps, scrubber: scrubber,
                                               labels: [chart.format(top), chart.format(top / 2)], tint: chart.tint)
                        }
                    }
                }
        }
    }

    private var title: some View {
        Label("\(track.lifetime.name) · \(chart.title)", systemImage: chart.symbol)
            .font(.headline)
            .foregroundStyle(chart.tint)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder private var legend: some View {
        Text(chart.lead)
            .font(.callout)
            .foregroundStyle(.secondaryText)
            .fixedSize()
            .help("Its figures over the part of the range it ran, counting recorded time only. Records that left it out as idle "
                + "count as nothing in an average.")
        ForEach(Array(chart.lines.enumerated()), id: \.element.id) { index, line in
            HStack(spacing: 5) {
                HistoryLineSample(line: line)
                Text(line.legend ?? line.name).foregroundStyle(.secondaryText)
                Text(index < chart.figures.count ? chart.figures[index] : "—").monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
            .help("\(line.name): \(line.meaning), over each \(HistoryInterval.adjective(bucket)) point. " + HistoryProcessStyle.idleHelp)
        }
    }

    /// The stretches with nothing to draw, and how: not running, dimmed;
    /// not watched, hatched like a gap.
    private var shading: (notRunning: [ClosedRange<Date>], unwatched: [HistoryGap]) {
        let lifetime = track.lifetime
        var notRunning: [ClosedRange<Date>] = []
        var unseen: [ClosedRange<Date>] = []
        func add(_ start: Date, _ end: Date, to list: inout [ClosedRange<Date>]) {
            let lower = max(start, domain.lowerBound)
            let upper = min(end, domain.upperBound)
            if lower < upper { list.append(lower...upper) }
        }
        add(domain.lowerBound, lifetime.started, to: &notRunning)
        if let ended = lifetime.ended {
            add(ended, domain.upperBound, to: &notRunning)
        }
        // History saw it only from its first record; one already running then wasn't watched before.
        if lifetime.firstSeen.timeIntervalSince(lifetime.started) > bucket {
            add(lifetime.started, lifetime.firstSeen, to: &unseen)
        }
        // Since its last sighting, unless it ended then; for one running now,
        // only once that's longer than a hiccup (this run hasn't recorded it yet).
        if lifetime.ended == nil,
           domain.upperBound.timeIntervalSince(lifetime.lastSeen) > (track.isRunning ? bucket * HistoryGap.spacing : 0) {
            add(lifetime.lastSeen, domain.upperBound, to: &unseen)
        }
        // Recorded by an older build, which kept no process history.
        for stretch in track.unwatched { add(stretch.lowerBound, stretch.upperBound, to: &unseen) }
        return (notRunning, unseen.map { HistoryGap(start: $0.lowerBound, end: $0.upperBound) })
    }

    private func plot(_ points: [HistoryPoint], top: Double) -> some View {
        let dark = colorScheme == .dark
        let wash = HistoryGapStyle.wash(dark: dark)
        let (notRunning, unwatched) = shading
        return Chart {
            stretchMarks(notRunning: notRunning, unwatched: unwatched, dark: dark, wash: wash)
            fillMarks(points, top: top)
            ForEach(gaps.shades.indices, id: \.self) { index in
                let shade = gaps.shades[index]
                RectangleMark(xStart: .value("Time", shade.start), xEnd: .value("Time", shade.end))
                    .foregroundStyle(Self.style(of: shade.kind, wash: wash))
            }
            lineMarks(points, top: top)
            // Where it started and ended, when that's within the range.
            ForEach(edges, id: \.self) { edge in
                RuleMark(x: .value("Time", edge))
                    .foregroundStyle(HistoryProcessStyle.tint.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(values: [0, top / 2, top]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.055))
                AxisValueLabel(format: timeLabels, anchor: .top).font(.system(size: 11)).foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background(LinearGradient(colors: [chart.tint.opacity(0.10), chart.tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .overlay { HistoryGapHatch(gaps: gaps.drawn + unwatched, domain: domain) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The stretches it wasn't running, was idle and so not stored, or
    /// wasn't watched, each drawn its own way and never as zero.
    @ChartContentBuilder
    private func stretchMarks(notRunning: [ClosedRange<Date>], unwatched: [HistoryGap], dark: Bool, wash: Color) -> some ChartContent {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        ForEach(notRunning.indices, id: \.self) { index in
            let stretch = notRunning[index]
            RectangleMark(xStart: .value("Time", stretch.lowerBound), xEnd: .value("Time", stretch.upperBound))
                .foregroundStyle(HistoryProcessStyle.notRunning(dark: dark))
                .annotation(position: .overlay, alignment: .bottomLeading) {
                    if stretch.upperBound.timeIntervalSince(stretch.lowerBound) > span / 5 {
                        Text("Not running").font(.metadata).foregroundStyle(.secondaryText).padding([.leading, .bottom], 6)
                    }
                }
        }
        ForEach(track.idle.indices, id: \.self) { index in
            let stretch = track.idle[index]
            RectangleMark(xStart: .value("Time", max(stretch.lowerBound, domain.lowerBound)), xEnd: .value("Time", stretch.upperBound))
                .foregroundStyle(HistoryProcessStyle.idle(dark: dark))
                .annotation(position: .overlay, alignment: .bottomLeading) {
                    if stretch.upperBound.timeIntervalSince(stretch.lowerBound) > span / 6 {
                        Text("Idle, not stored").font(.metadata).foregroundStyle(.secondaryText).padding([.leading, .bottom], 6)
                    }
                }
        }
        ForEach(unwatched) { gap in
            RectangleMark(xStart: .value("Time", gap.start), xEnd: .value("Time", gap.end))
                .foregroundStyle(wash)
        }
    }

    @ChartContentBuilder
    private func fillMarks(_ points: [HistoryPoint], top: Double) -> some ChartContent {
        ForEach(chart.lines.filter(\.fill)) { line in
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
    }

    @ChartContentBuilder
    private func lineMarks(_ points: [HistoryPoint], top: Double) -> some ChartContent {
        ForEach(chart.lines) { line in
            let runs = HistoryPoint.runs(points, value: line.value)
            ForEach(points.indices, id: \.self) { index in
                if let run = runs[index], let value = line.value(points[index].values) {
                    let series = "\(line.name) \(run)"
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
        ForEach(chart.lines) { line in
            ForEach(dots(on: line, points: points), id: \.self) { index in
                if let value = line.value(points[index].values) {
                    PointMark(x: .value("Time", points[index].time), y: .value(line.name, min(value, top)))
                        .foregroundStyle(line.color)
                        .symbolSize(18)
                }
            }
        }
    }

    /// Its start and its end (or last sighting), where they fall inside the range.
    private var edges: [Date] {
        let lifetime = track.lifetime
        var edges = [lifetime.started]
        if !track.isRunning { edges.append(lifetime.ended ?? lifetime.lastSeen) }
        return edges.filter { $0 > domain.lowerBound && $0 < domain.upperBound }
    }

    /// The points (by index) that get a dot on `line`: where it breaks off
    /// and picks up again, and a lone point.
    private func dots(on line: HistoryLine, points: [HistoryPoint]) -> [Int] {
        let runs = HistoryPoint.runs(points, value: line.value)
        let lone = HistoryPoint.lone(runs)
        let ends = line.stroke.marksBreaks ? HistoryPoint.breaks(points, runs: runs) : []
        let alone = lone.isEmpty ? [] : points.indices.filter { runs[$0].map(lone.contains) ?? false }
        return Set(ends + alone).filter { $0 < points.count }.sorted()
    }

    private static func style(of kind: HistoryGap.Shade.Kind, wash: Color) -> LinearGradient {
        let colors: [Color] = switch kind {
        case .fadeIn: [wash.opacity(0), wash]
        case .gap: [wash, wash]
        case .fadeOut: [wash, wash.opacity(0)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// The key's sample of an idle stretch: the wash with its edges.
struct HistoryIdleSample: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(HistoryProcessStyle.idle(dark: colorScheme == .dark))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HistoryProcessStyle.tint.opacity(0.35), lineWidth: 0.5))
            .frame(width: 18, height: 11)
    }
}

/// The picked process's lifetime as a lane over the rail's track: a bar
/// from its start to its end (to the right edge while it runs), named
/// where there's room, its idle stretches paler. Takes no room while
/// nothing is picked. Reads only the process store, so the pointer and
/// playback never redraw it.
struct HistoryProcessLane: View {
    let domain: ClosedRange<Date>
    private let store = HistoryProcessStore.shared

    var body: some View {
        if store.picked != nil, let track = store.track, let span = track.lifetime.span(within: domain, isRunning: track.isRunning,
                                                                                        now: domain.upperBound) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let lower = HistoryMoment.x(of: span.lowerBound, width: width, domain: domain)
                let upper = HistoryMoment.x(of: span.upperBound, width: width, domain: domain)
                let length = max(upper - lower, 4)
                let start = min(lower, width - length)
                ZStack(alignment: .leading) {
                    // Holds the lane's left edge, which the bar is placed from.
                    Color.clear.frame(width: width, height: 1)
                    bar(track, length: length)
                        .alignmentGuide(.leading) { _ in -start }
                }
                .frame(width: width, height: geometry.size.height, alignment: .leading)
            }
            .frame(height: 16)
            .help(help(track, span: span))
        }
    }

    private func bar(_ track: HistoryProcessStore.Track, length: CGFloat) -> some View {
        let tint = HistoryProcessStyle.tint
        return Text(length >= 60 ? "\(track.lifetime.name) · PID \(String(track.lifetime.identity.pid))" : "")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(width: length, height: 14, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.7)))
    }

    private func help(_ track: HistoryProcessStore.Track, span: ClosedRange<Date>) -> String {
        let lifetime = track.lifetime
        return "\(lifetime.name), PID \(lifetime.identity.pid): ran \(HistoryProcessStyle.span(span)) in this range. "
            + HistoryProcessStyle.state(lifetime, isRunning: track.isRunning) + "."
    }
}

/// The picked process's lifetime along the folded strip's track: a slim
/// tinted bar under it.
struct HistoryProcessStripBand: View {
    let domain: ClosedRange<Date>
    private let store = HistoryProcessStore.shared

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            if store.picked != nil, let track = store.track,
               let span = track.lifetime.span(within: domain, isRunning: track.isRunning, now: domain.upperBound) {
                let lower = HistoryMoment.x(of: span.lowerBound, width: width, domain: domain)
                let upper = HistoryMoment.x(of: span.upperBound, width: width, domain: domain)
                Capsule()
                    .fill(HistoryProcessStyle.tint.opacity(0.8))
                    .frame(width: max(upper - lower, 3), height: 3)
                    .offset(x: min(lower, width - 3), y: geometry.size.height - 3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The picked process at the moment shown: its figures over that point, or
/// that it was idle, not running, or not recorded then.
struct HistoryMomentProcess: View {
    @Environment(AppModel.self) private var model
    let time: Date
    private let store = HistoryProcessStore.shared

    /// What the process was doing at the moment.
    enum Moment {
        case figures(ProcessHistoryPoint)
        case idle
        case notRunning
        case notRecorded
    }

    static func moment(of track: HistoryProcessStore.Track, at time: Date) -> Moment {
        let lifetime = track.lifetime
        if time < lifetime.started.addingTimeInterval(-track.bucket) { return .notRunning }
        if let ended = lifetime.ended, time > ended.addingTimeInterval(track.bucket) { return .notRunning }
        guard let point = ProcessHistoryPoint.at(time, in: track.figures, bucket: track.bucket) else { return .notRecorded }
        return point.state == .idle ? .idle : .figures(point)
    }

    var body: some View {
        if store.picked != nil, let track = store.track {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(HistoryProcessStyle.tint).frame(width: 7, height: 7)
                    Text(track.lifetime.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("PID \(String(track.lifetime.identity.pid))").font(.callout).foregroundStyle(.secondaryText).fixedSize()
                }
                switch Self.moment(of: track, at: time) {
                case .figures(let point):
                    figures(point, restricted: track.lifetime.isRestricted)
                case .idle:
                    note("Idle, not stored: running, but under every keep threshold then")
                        .help(HistoryProcessStyle.idleHelp)
                case .notRunning:
                    note("Not running then")
                case .notRecorded:
                    note("Not recorded then")
                }
            }
        }
    }

    private func figures(_ point: ProcessHistoryPoint, restricted: Bool) -> some View {
        let scale = model.cpuScale
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("CPU", Theme.cpu, point.cpu.map(scale.format) ?? "—",
                detail: point.cpuPeak.map { "peak \(scale.format($0))" } ?? "")
            row(restricted ? "Resident" : "Footprint", Theme.memory, point.memory.map { Format.bytes(UInt64(max($0, 0))) } ?? "—")
            if !restricted {
                row("Disk read", Theme.disk, point.diskRead.map(Format.bytesPerSecond) ?? "—")
                row("Disk write", Theme.diskSecondary, point.diskWrite.map(Format.bytesPerSecond) ?? "—")
            }
            if point.state == .partlyIdle {
                GridRow {
                    Text("Idle, not stored, in \(point.records - point.stored) of \(point.records) records here")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .gridCellColumns(2)
                        .help(HistoryProcessStyle.idleHelp)
                }
            }
        }
        .font(.callout)
    }

    private func row(_ name: String, _ color: Color, _ value: String, detail: String = "") -> some View {
        GridRow(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 6) {
                Text(value).fontWeight(.medium).monospacedDigit()
                if !detail.isEmpty {
                    Text(detail).foregroundStyle(.secondaryText).monospacedDigit()
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.explanation).foregroundStyle(.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

/// The picked process at the moment, on one line, for the narrow window's
/// summary band: "Safari · CPU 3.2% · 1.2 GB", or what it was doing.
struct HistoryMomentProcessLine: View {
    @Environment(AppModel.self) private var model
    let time: Date?
    private let store = HistoryProcessStore.shared

    var body: some View {
        if store.picked != nil, let track = store.track, let time {
            HStack(spacing: 6) {
                Circle().fill(HistoryProcessStyle.tint).frame(width: 6, height: 6)
                Text(track.lifetime.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(text(HistoryMomentProcess.moment(of: track, at: time), restricted: track.lifetime.isRestricted))
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
    }

    private func text(_ moment: HistoryMomentProcess.Moment, restricted: Bool) -> String {
        switch moment {
        case .figures(let point):
            var parts = [point.cpu.map { "CPU " + model.cpuScale.format($0) }, point.memory.map { Format.bytes(UInt64(max($0, 0))) }]
            if !restricted, let read = point.diskRead, let write = point.diskWrite {
                parts.append("disk \(Format.bytesPerSecond(read + write))")
            }
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .idle: return "idle, not stored"
        case .notRunning: return "not running"
        case .notRecorded: return "not recorded"
        }
    }
}
