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

    /// The charts worth drawing for these points: GPU, power and temperature
    /// only when the Mac reported them.
    static func all(for points: [HistoryPoint]) -> [HistoryChartSpec] {
        func has(_ value: (HistoryValues) -> Double?) -> Bool { points.contains { value($0.values) != nil } }
        var specs = [
            HistoryChartSpec(title: "CPU", symbol: "cpu", tint: Theme.cpu, lines: [
                HistoryLine(name: "Average", color: Theme.cpu, value: { $0.cpu }),
                HistoryLine(name: "Busiest moment", color: Theme.cpu.opacity(0.7), value: { $0.cpuPeak },
                            fill: false, dashed: true, summary: .maximum),
            ], format: { Format.percent($0) }, ceiling: 1),
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

    /// Top of the scale for these points.
    func top(for points: [HistoryPoint]) -> Double {
        if let ceiling { return ceiling }
        let peak = points.reduce(0.0) { result, point in
            lines.reduce(result) { max($0, $1.value(point.values) ?? 0) }
        }
        return GraphMath.ceiling(peak: peak, floor: floor, units: units)
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
/// time, so moving the pointer redraws the scrubber overlay and not the chart.
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

    var body: some View {
        let top = spec.top(for: points)
        Card(tint: spec.tint) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Label(spec.title, systemImage: spec.symbol)
                    .font(.headline)
                    .foregroundStyle(spec.tint)
                Spacer()
                ForEach(spec.lines) { line in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(line.color).frame(width: 9, height: 9)
                        Text(line.name).foregroundStyle(.secondary)
                        Text(spec.summary(of: line, in: points)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            chart(top: top)
                .frame(height: 130)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            HistoryPlotOverlay(plot: geometry[anchor], domain: domain, scrubber: scrubber,
                                               labels: [spec.format(top), spec.format(top / 2)], tint: spec.tint)
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
                            Text("Not recorded yet").font(.caption).foregroundStyle(.tertiary)
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
                AxisValueLabel(format: timeLabels).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .chartPlotStyle { plot in
            plot.background(LinearGradient(colors: [spec.tint.opacity(0.10), spec.tint.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Axis labels inside the plot, the hover target that moves the scrubber, and
/// the scrubber line itself.
private struct HistoryPlotOverlay: View {
    let plot: CGRect
    let domain: ClosedRange<Date>
    let scrubber: HistoryScrubber
    /// Top and middle of the scale.
    let labels: [String]
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(x: plot.minX + 6, y: plot.minY + 3 + plot.height / 2 * CGFloat(index))
            }
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: plot.width, height: plot.height)
                .offset(x: plot.minX, y: plot.minY)
                .onContinuousHover { phase in
                    guard case .active(let location) = phase, plot.width > 0 else { return }
                    let fraction = min(max(location.x / plot.width, 0), 1)
                    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                    scrubber.time = domain.lowerBound.addingTimeInterval(span * fraction)
                }
            HistoryScrubberLine(scrubber: scrubber, plot: plot, domain: domain, tint: tint)
        }
    }
}

/// The vertical line at the scrubbed moment. It alone reads the scrubber, so
/// it's the only part of a chart that redraws as the pointer moves.
private struct HistoryScrubberLine: View {
    let scrubber: HistoryScrubber
    let plot: CGRect
    let domain: ClosedRange<Date>
    let tint: Color

    var body: some View {
        if let time = scrubber.time, domain.contains(time) {
            let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
            let x = plot.minX + plot.width * time.timeIntervalSince(domain.lowerBound) / max(span, 1)
            Rectangle()
                .fill(LinearGradient(colors: [tint.opacity(0.9), .white.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1.5, height: plot.height)
                .offset(x: x - 0.75, y: plot.minY)
                .allowsHitTesting(false)
        }
    }
}
