import Charts
import OTMKit
import SwiftUI

/// One line on a history chart.
struct HistoryLine: Identifiable {
    enum Summary {
        case average
        case maximum
    }

    var id: String { name }
    let name: String
    let color: Color
    let value: (HistoryValues) -> Double?
    var fill = true
    var dashed = false
    /// How the legend sums the line up over the range.
    var summary = Summary.average
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
                HistoryLine(name: "Average", color: Theme.cpu, value: { $0.cpu }),
                HistoryLine(name: "Busiest moment", color: Theme.cpu.opacity(0.7), value: { $0.cpuPeak },
                            fill: false, dashed: true, summary: .maximum),
            ], format: { Format.percent($0) }, ceiling: 1, followsCPUScale: true),
            HistoryChartSpec(title: "Memory", symbol: "memorychip", tint: Theme.memory, lines: [
                HistoryLine(name: "Used", color: Theme.memory, value: { $0.memory }),
                HistoryLine(name: "Pressure", color: Theme.wired, value: { $0.memoryPressure }, fill: false),
            ], format: { Format.percent($0) }, ceiling: 1),
        ]
        if has({ $0.gpu }) {
            specs.append(HistoryChartSpec(title: "GPU", symbol: "square.stack.3d.up", tint: Theme.gpu, lines: [
                HistoryLine(name: "Busiest GPU", color: Theme.gpu, value: { $0.gpu }),
            ], format: { Format.percent($0) }, ceiling: 1))
        }
        if has({ $0.systemWatts }) {
            specs.append(HistoryChartSpec(title: "Power", symbol: "bolt.fill", tint: Theme.power, lines: [
                HistoryLine(name: "System", color: Theme.power, value: { $0.systemWatts }),
                HistoryLine(name: "CPU", color: Theme.cpu, value: { $0.cpuWatts }, fill: false),
                HistoryLine(name: "GPU", color: Theme.gpu, value: { $0.gpuWatts }, fill: false),
            ], format: Format.watts, floor: 10))
        }
        specs.append(HistoryChartSpec(title: "Disk", symbol: "internaldrive", tint: Theme.disk, lines: [
            HistoryLine(name: "Read", color: Theme.disk, value: { $0.diskRead }),
            HistoryLine(name: "Write", color: Theme.diskSecondary, value: { $0.diskWrite }, fill: false),
        ], format: Format.bytesPerSecond, floor: 1_048_576, units: .binaryBytes))
        specs.append(HistoryChartSpec(title: "Network", symbol: "network", tint: Theme.network, lines: [
            HistoryLine(name: "Received", color: Theme.network, value: { $0.networkIn }),
            HistoryLine(name: "Sent", color: Theme.networkSecondary, value: { $0.networkOut }, fill: false),
        ], format: Format.bitsPerSecond, floor: 125_000, units: .bits))
        if has({ $0.chipCelsius }) {
            specs.append(HistoryChartSpec(title: "Temperature", symbol: "thermometer.medium", tint: Theme.thermal, lines: [
                HistoryLine(name: "Chip, hottest die", color: Theme.thermal, value: { $0.chipCelsius }),
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

    func summary(of line: HistoryLine, in points: [HistoryPoint]) -> String {
        let values = points.compactMap { line.value($0.values) }
        guard !values.isEmpty else { return "—" }
        switch line.summary {
        case .average: return "avg " + format(values.reduce(0, +) / Double(values.count))
        case .maximum: return "max " + format(values.max() ?? 0)
        }
    }
}

/// One history chart in a card. It takes only values, never the scrubber's
/// moments, so moving the pointer redraws the markers and not the chart.
struct HistoryChartCard: View {
    let spec: HistoryChartSpec
    let points: [HistoryPoint]
    let domain: ClosedRange<Date>
    /// When the recording began; the chart dims the time before it.
    let earliest: Date?
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

    private var legend: some View {
        ForEach(spec.lines) { line in
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(line.color).frame(width: 9, height: 9)
                Text(line.name).foregroundStyle(.secondaryText)
                Text(spec.summary(of: line, in: points)).monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
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
                            HistoryPlotOverlay(plot: geometry[anchor], domain: domain, points: points, scrubber: scrubber,
                                               labels: axisLabels(top: top), tint: spec.tint)
                        }
                    }
                }
        }
    }

    private func chart(top: Double) -> some View {
        Chart {
            if let earliest, earliest > domain.lowerBound {
                RectangleMark(xStart: .value("Time", domain.lowerBound), xEnd: .value("Time", min(earliest, domain.upperBound)))
                    .foregroundStyle(.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
                    .annotation(position: .overlay, alignment: .center) {
                        if earliest.timeIntervalSince(domain.lowerBound) > domain.upperBound.timeIntervalSince(domain.lowerBound) / 5 {
                            Text("Not recorded yet").font(.subheadline).foregroundStyle(.tertiary)
                        }
                    }
            }
            ForEach(spec.lines) { line in
                ForEach(points) { point in
                    if let value = line.value(point.values) {
                        let series = "\(line.name) \(point.segment)"
                        if line.fill {
                            AreaMark(x: .value("Time", point.time), y: .value(line.name, min(value, top)),
                                     series: .value("Series", series), stacking: .unstacked)
                                .foregroundStyle(LinearGradient(colors: [line.color.opacity(0.42), line.color.opacity(0.03)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                        // A wide faint stroke under the line, for the glow.
                        LineMark(x: .value("Time", point.time), y: .value(line.name, min(value, top)),
                                 series: .value("Series", series + " glow"))
                            .foregroundStyle(line.color.opacity(line.dashed ? 0 : 0.22))
                            .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", point.time), y: .value(line.name, min(value, top)),
                                 series: .value("Series", series))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: line.dashed ? 1.1 : 1.6, lineCap: .round, lineJoin: .round,
                                                   dash: line.dashed ? [4, 3] : []))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(values: [0, top / 2, top]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.10))
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.07))
                // Centred under its line, as `GraphMath.timeTicks` spaces them: a
                // label hanging right of its tick ran past the plot's end and was cut.
                AxisValueLabel(format: timeLabels, anchor: .top).font(.system(size: 10.5)).foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background(LinearGradient(colors: [spec.tint.opacity(0.10), spec.tint.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Where moments sit on the History page's time axes, and how they read.
enum HistoryMoment {
    /// The recorded moment nearest `x` across a plot `width` wide spanning
    /// `domain`, so a pin always lands on a point with figures behind it.
    static func at(x: CGFloat, width: CGFloat, domain: ClosedRange<Date>, points: [HistoryPoint]) -> Date? {
        guard width > 0 else { return nil }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let time = domain.lowerBound.addingTimeInterval(span * min(max(x / width, 0), 1))
        return HistoryPoint.nearest(to: time, in: points)?.time ?? time
    }

    /// How far across a plot `width` wide `time` sits.
    static func x(of time: Date, width: CGFloat, domain: ClosedRange<Date>) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return width * time.timeIntervalSince(domain.lowerBound) / max(span, 1)
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
/// and a click or drag pins one, and the moment markers.
private struct HistoryPlotOverlay: View {
    let plot: CGRect
    let domain: ClosedRange<Date>
    let points: [HistoryPoint]
    let scrubber: HistoryScrubber
    /// Top and middle of the scale.
    let labels: [String]
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index])
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
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
                    case .active(let location): scrubber.hovered = moment(at: location.x)
                    case .ended: scrubber.hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { scrubber.pinned = moment(at: $0.location.x) })
            HistoryMarkers(scrubber: scrubber, plot: plot, domain: domain, tint: tint)
        }
    }

    private func moment(at x: CGFloat) -> Date? {
        HistoryMoment.at(x: x, width: plot.width, domain: domain, points: points)
    }
}

/// The pinned moment's line, with a bead at the top under the rail's
/// handle, a fainter dashed line at a moment the pointer previews, and the
/// session being marked or picked shaded. It alone reads the scrubber, so
/// it's the only part of a chart that redraws as the pointer moves or
/// playback steps.
private struct HistoryMarkers: View {
    let scrubber: HistoryScrubber
    let plot: CGRect
    let domain: ClosedRange<Date>
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let marked = scrubber.marked {
                band(marked.start, marked.end)
            }
            if let hovered = scrubber.hovered, hovered != scrubber.pinned, domain.contains(hovered) {
                Path { path in
                    path.move(to: CGPoint(x: 0.5, y: 0))
                    path.addLine(to: CGPoint(x: 0.5, y: plot.height))
                }
                .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 1, height: plot.height)
                .offset(x: x(of: hovered) - 0.5, y: plot.minY)
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

    private func x(of time: Date) -> CGFloat {
        plot.minX + HistoryMoment.x(of: time, width: plot.width, domain: domain)
    }
}
