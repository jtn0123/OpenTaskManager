import Charts
import OTMKit
import SwiftUI

/// The hardware charts the History page can show below its own: one at a
/// time, picked from what the recording holds.
enum HistoryHardwareChart: String, CaseIterable, Identifiable {
    case cores
    case eachCore
    case clocks
    case temperatures
    case fans
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cores: "Core types"
        case .eachCore: "Each core"
        case .clocks: "Clocks"
        case .temperatures: "Temperatures"
        case .fans: "Fans"
        case .power: "Power rails"
        }
    }

    var kind: HistoryHardwareSeries.Kind? {
        switch self {
        case .cores: .load
        case .eachCore: nil
        case .clocks: .clock
        case .temperatures: .temperature
        case .fans: .fan
        case .power: .power
        }
    }

    /// The charts `track` has something for, in picker order.
    static func available(_ track: HistoryHardwareTrack) -> [Self] {
        let kinds = Set(track.series.map(\.kind))
        return allCases.filter { chart in
            chart == .eachCore ? track.coreCount > 0 : chart.kind.map(kinds.contains) ?? false
        }
    }

    /// The chart's spec over `series` (the track's), each line stroked its
    /// own way in order, so no two differ by colour alone.
    func spec(series: [HistoryHardwareSeries], hasChipTemperature: Bool) -> HistoryChartSpec {
        let picked = series.filter { $0.kind == kind }
        var lines: [HistoryLine] = []
        if self == .temperatures, hasChipTemperature {
            lines.append(HistoryLine(name: "Hottest die", color: Theme.thermal, value: { $0.chipCelsius },
                                     meaning: "the hottest sensor on the chip's die", note: "As on the Temperature chart above."))
        }
        for series in picked {
            let id = series.id
            lines.append(HistoryLine(name: series.label, color: Self.color(of: series, index: lines.count),
                                     value: { $0.hardware[id] }, meaning: Self.meaning(of: series),
                                     note: "Read from \(series.source)."))
        }
        let strokes = HistoryLine.Stroke.allCases
        for index in lines.indices {
            lines[index].stroke = strokes[index % strokes.count]
            lines[index].fill = index == 0
        }
        return switch self {
        case .cores, .eachCore:
            HistoryChartSpec(title: "Core types", symbol: "cpu", tint: Theme.cpu, lines: lines, format: { Format.percent($0) },
                             ceiling: 1, followsCPUScale: true)
        case .clocks:
            HistoryChartSpec(title: "Clocks", symbol: "speedometer", tint: Theme.cpu, lines: lines,
                             format: { Format.frequency(megahertz: $0) }, floor: 1_000)
        case .temperatures:
            HistoryChartSpec(title: "Temperatures", symbol: "thermometer.medium", tint: Theme.thermal, lines: lines,
                             format: Format.celsius, floor: 60)
        case .fans:
            HistoryChartSpec(title: "Fans", symbol: "fan", tint: Theme.fan, lines: lines, format: Format.rpm, floor: 2_000)
        case .power:
            HistoryChartSpec(title: "Power rails", symbol: "bolt.horizontal", tint: Theme.power, lines: lines, format: Format.watts,
                             floor: 5)
        }
    }

    /// What a series' line plots, for its legend's tooltip.
    private static func meaning(of series: HistoryHardwareSeries) -> String {
        switch series.kind {
        case .load:
            series.id == HistoryHardwareSeries.busiestCore
                ? "the load of whichever logical CPU was busiest at each update" : "the average load across the \(series.label.lowercased())"
        case .clock:
            series.id == "gpu.clock" ? "the GPU's clock while it ran, idle time left out"
                : "the cluster's clock while it ran, idle time left out; an idle cluster has none"
        case .temperature:
            series.id == "temperature.average" ? "the average of the die's sensors" : "the hottest \(series.label) sensor"
        case .fan: "the fan's speed"
        case .power: "the \(series.label) power draw; none while its counters stall or, for DC input, while unplugged"
        }
    }

    private static func color(of series: HistoryHardwareSeries, index: Int) -> Color {
        switch series.id {
        case "gpu.clock", "temperature.gpu": Theme.gpu
        case "temperature.cpu": Theme.cpu
        case "temperature.ssd": Theme.sensor(.storage)
        case "temperature.battery": Theme.sensor(.battery)
        case "temperature.average": Theme.network
        case "power.ane": Theme.neuralEngine
        case "power.dram": Theme.dram
        case "power.input": Theme.power
        case HistoryHardwareSeries.busiestCore: Theme.series(3)
        default:
            switch series.kind {
            case .load: Theme.tier(series.rank)
            case .fan: index == 0 ? Theme.fan : Theme.series(index)
            default: Theme.series(index)
            }
        }
    }
}

/// The hardware series below the History page's charts: core loads,
/// clocks, temperatures, fans and power rails, one chart at a time behind a
/// picker. Folded to one line until shown, so the page is no longer than it
/// was; read from the recorder only while shown, once per graph point.
struct HistoryHardwareSection: View {
    let recorder: FlightRecorder?
    /// The page's points, whose times, segments and gaps the charts share.
    let points: [HistoryPoint]
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    /// When the live recording began; nil for a file.
    let earliest: Date?
    let isFile: Bool
    let gaps: HistoryGapMarks
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber

    @AppStorage("historyHardwareShown") private var shown = false
    @AppStorage("historyHardwareChart") private var picked = HistoryHardwareChart.cores
    @State private var track: HistoryHardwareTrack?

    private struct LoadKey: Equatable {
        let shown: Bool
        let recording: URL?
        let domain: ClosedRange<Date>
        let bucket: TimeInterval
        let revision: Date?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if shown {
                if let track {
                    content(track)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: LoadKey(shown: shown, recording: recorder?.url, domain: domain, bucket: bucket, revision: points.last?.time)) {
            guard shown, let recorder else { return }
            track = (try? await recorder.hardware(from: domain.lowerBound, to: domain.upperBound, bucket: bucket)) ?? .empty
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Hardware", systemImage: "memorychip.fill")
                .font(.headline)
                .foregroundStyle(.secondaryText)
                .fixedSize()
            // Wraps in a narrow window rather than cut off.
            Text("Core loads, clocks, temperatures, fans and power rails")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(shown ? "Hide" : "Show") { shown.toggle() }
                .controlSize(.small)
                .help(shown ? "Fold the hardware charts away." : "Show charts of the hardware figures recorded beside the ones above.")
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func content(_ track: HistoryHardwareTrack) -> some View {
        let hasChip = points.contains { $0.values.chipCelsius != nil }
        let charts = HistoryHardwareChart.available(track)
        if charts.isEmpty {
            Text(isFile
                 ? "This recording has no hardware figures: it was saved by an earlier OpenTaskManager or on a Mac without "
                    + "them, or it's a spike capture, which keeps the figures above second by second but not these."
                 : "No hardware figures in this range yet. They're recorded every \(Int(FlightRecorder.span)) seconds from now on; "
                    + "earlier records don't have them.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        } else {
            let chart = charts.contains(picked) ? picked : charts[0]
            picker(charts, chart: chart)
            let shownPoints = track.overlay(points)
            // Unrecorded until the hardware figures began, but for the hottest
            // die, which is the page's own and goes back further.
            let since = isFile ? nil : chart == .temperatures && hasChip ? earliest : [earliest, track.earliest].compactMap { $0 }.max()
            if chart == .eachCore {
                HistoryCoreMapCard(points: shownPoints, coreCount: track.coreCount, bucket: bucket, domain: domain,
                                   earliest: since, gaps: gaps, ticks: ticks, timeLabels: timeLabels, scrubber: scrubber)
            } else {
                HistoryChartCard(spec: chart.spec(series: track.series, hasChipTemperature: hasChip), points: shownPoints,
                                 bucket: bucket, domain: domain, earliest: since, gaps: gaps, ticks: ticks,
                                 timeLabels: timeLabels, scrubber: scrubber)
            }
        }
    }

    /// The charts side by side while they fit, else a menu.
    private func picker(_ charts: [HistoryHardwareChart], chart: HistoryHardwareChart) -> some View {
        let selection = Binding(get: { chart }, set: { picked = $0 })
        return ViewThatFits(in: .horizontal) {
            Picker("Hardware chart", selection: selection) {
                ForEach(charts) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Chart", selection: selection) {
                ForEach(charts) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .labelsHidden()
    }
}

/// Each logical CPU's load over time, a row per CPU from CPU 0 at the top,
/// darker where it was busier. The cells are drawn in one `Canvas` behind
/// the chart, which keeps the axis, gaps and scrubber of the others.
private struct HistoryCoreMapCard: View {
    let points: [HistoryPoint]
    let coreCount: Int
    let bucket: TimeInterval
    let domain: ClosedRange<Date>
    let earliest: Date?
    let gaps: HistoryGapMarks
    let ticks: [Date]
    let timeLabels: Date.FormatStyle
    let scrubber: HistoryScrubber
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Card(tint: Theme.cpu) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    title
                    Spacer(minLength: 0)
                    legend
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    legend
                }
            }
            chart
                .frame(height: max(130, CGFloat(coreCount) * 7))
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            HistoryPlotOverlay(plot: geometry[anchor], domain: domain, points: points, gaps: gaps,
                                               scrubber: scrubber, labels: [], tint: Theme.cpu)
                        }
                    }
                }
        }
    }

    private var title: some View {
        Label("Each core", systemImage: "square.grid.3x3.fill")
            .font(.headline)
            .foregroundStyle(Theme.cpu)
            .fixedSize()
    }

    /// The scale, idle to fully busy, and how the rows run.
    private var legend: some View {
        HStack(spacing: 6) {
            Text("CPU 0 at top · \(coreCount) logical CPUs").foregroundStyle(.secondaryText)
            Text("0%").foregroundStyle(.secondaryText)
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Self.color(0), Self.color(1)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 44, height: 9)
            Text("100%").foregroundStyle(.secondaryText)
        }
        .font(.callout)
        .fixedSize()
        .help("Each row is one logical CPU, CPU 0 at the top; each cell its load averaged over "
            + "each \(HistoryInterval.adjective(bucket)) point. Gaps are left empty.")
    }

    private var chart: some View {
        let wash = HistoryGapStyle.wash(dark: colorScheme == .dark)
        return Chart {
            if let earliest, earliest > domain.lowerBound {
                RectangleMark(xStart: .value("Time", domain.lowerBound), xEnd: .value("Time", min(earliest, domain.upperBound)))
                    .foregroundStyle(.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
            }
            ForEach(gaps.shades.indices, id: \.self) { index in
                RectangleMark(xStart: .value("Time", gaps.shades[index].start), xEnd: .value("Time", gaps.shades[index].end))
                    .foregroundStyle(gaps.shades[index].kind == .gap ? wash : wash.opacity(0.5))
            }
            // Keeps the axes when there's nothing else to draw.
            RuleMark(y: .value("Load", 0)).foregroundStyle(.clear)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel(format: timeLabels, anchor: .top).font(.system(size: 11)).foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background {
                HistoryCoreMap(points: points, coreCount: coreCount, bucket: bucket, domain: domain)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// A cell's colour for a load from 0 to 1.
    static func color(_ load: Double) -> Color {
        Theme.cpu.opacity(0.06 + 0.94 * min(max(load, 0), 1))
    }
}

/// The cells of `HistoryCoreMapCard`: for each point, a column of cells
/// over the stretch it averages, one per CPU; a CPU without a reading there
/// gets none.
private struct HistoryCoreMap: View {
    let points: [HistoryPoint]
    let coreCount: Int
    let bucket: TimeInterval
    let domain: ClosedRange<Date>

    var body: some View {
        Canvas { context, size in
            guard coreCount > 0 else { return }
            let span = max(domain.upperBound.timeIntervalSince(domain.lowerBound), 1)
            let row = size.height / CGFloat(coreCount)
            func x(_ time: Date) -> CGFloat { size.width * time.timeIntervalSince(domain.lowerBound) / span }
            for point in points where !point.values.coreLoads.isEmpty {
                let right = x(point.time)
                let left = x(point.time.addingTimeInterval(-bucket))
                // A hairline between columns and rows, so cells read apart.
                let rect = CGRect(x: left, y: 0, width: max(right - left - 0.5, 0.5), height: row)
                for (core, load) in point.values.coreLoads.prefix(coreCount).enumerated() {
                    guard let load else { continue }
                    let cell = rect.offsetBy(dx: 0, dy: CGFloat(core) * row).insetBy(dx: 0, dy: row > 4 ? 0.5 : 0)
                    context.fill(Path(cell), with: .color(HistoryCoreMapCard.color(load)))
                }
            }
        }
        .accessibilityLabel("Each core's load over time")
    }
}
