import OTMKit
import SwiftUI

/// The floating mini monitor's content: a figure and a minute's small graph
/// for each picked meter, from the store's own readings (`MiniMonitorStore`),
/// so it shows the same with the main window open, hidden or closed.
/// Figures are plain text and graphs step once a point: nothing here
/// animates between readings.
struct MiniMonitorView: View {
    @Environment(AppModel.self) private var model
    @Setting(Settings.miniMonitorMeters) private var meters: MiniMonitorMeters
    /// The content's size, for the panel to fit (`MiniMonitorController`).
    var sizeChanged: (CGSize) -> Void

    init(sizeChanged: @escaping (CGSize) -> Void) {
        self.sizeChanged = sizeChanged
    }

    var body: some View {
        let reading = model.miniMonitor.reading
        VStack(alignment: .leading, spacing: 8) {
            ForEach(meters.shown.filter { shows($0, reading.figures) }) { meter in
                row(meter, reading)
            }
            if model.isPaused {
                Label("Updates paused", systemImage: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .fixedSize()
        .environment(\.streamsGraphs, false)
        .environment(\.sampleInterval, reading.step)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
        .samplingDemand(.miniMonitor)
    }

    /// GPU load and power are left out where the Mac doesn't give them.
    private func shows(_ meter: MiniMonitorMeter, _ figures: MiniMonitorFigures?) -> Bool {
        switch meter {
        case .gpu: figures?.gpu != nil
        case .power: figures?.watts != nil
        default: true
        }
    }

    @ViewBuilder private func row(_ meter: MiniMonitorMeter, _ reading: MiniMonitorReading) -> some View {
        let figures = reading.figures
        switch meter {
        case .cpu:
            MiniMonitorRow(title: meter.title, lines: [figures.map { Format.percent($0.cpu) }],
                           series: [GraphSeries(values: reading.cpu, color: Theme.cpu)], maxValue: 1)
        case .memory:
            MiniMonitorRow(title: meter.title,
                           lines: [figures.map { "\(Format.bytes($0.memoryUsed)) · \($0.pressure.rawValue.capitalized)" }],
                           series: [GraphSeries(values: reading.memory, color: Theme.memory)], maxValue: 1)
        case .gpu:
            MiniMonitorRow(title: meter.title, lines: [figures?.gpu.map { Format.percent($0) }],
                           series: [GraphSeries(values: reading.gpu, color: Theme.gpu)], maxValue: 1)
        case .network:
            MiniMonitorRow(title: meter.title,
                           lines: [figures.map { "↓ " + Format.bitsPerSecond($0.networkIn) },
                                   figures.map { "↑ " + Format.bitsPerSecond($0.networkOut) }],
                           series: pair(reading.networkIn, reading.networkOut, Theme.network, Theme.networkSecondary),
                           minimumCeiling: 125_000)
        case .disk:
            MiniMonitorRow(title: meter.title,
                           lines: [figures.map { "R " + Format.bytesPerSecond($0.diskRead) },
                                   figures.map { "W " + Format.bytesPerSecond($0.diskWrite) }],
                           series: pair(reading.diskRead, reading.diskWrite, Theme.disk, Theme.diskSecondary),
                           minimumCeiling: 1_048_576)
        case .power:
            MiniMonitorRow(title: meter.title, lines: [figures?.watts.map { Format.watts($0) }],
                           series: [GraphSeries(values: reading.power, color: Theme.power)], minimumCeiling: 5)
        }
    }

    /// As the Overview's throughput cards draw them: the first filled, the second dashed.
    private func pair(_ first: [Double], _ second: [Double], _ color: Color, _ secondColor: Color) -> [GraphSeries] {
        [GraphSeries(values: first, color: color), GraphSeries(values: second, color: secondColor, fill: false, dashed: true)]
    }
}

/// One meter: its name and figures on the left, its graph on the right.
private struct MiniMonitorRow: View {
    var title: String
    /// Nil before the first reading.
    var lines: [String?]
    var series: [GraphSeries]
    var maxValue: Double?
    var minimumCeiling: Double = 0

    var body: some View {
        let color = series.first?.color ?? .secondary
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index] ?? "—")
                        .font(lines.count > 1 ? .caption.weight(.medium) : .callout.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(width: 104, alignment: .leading)
            GraphView(series: series, maxValue: maxValue, capacity: MiniMonitorFeed.points, showsGrid: false,
                      lineWidth: 1.35, glows: true, minimumCeiling: minimumCeiling, cornerRadius: 3)
                .plotFrame(tint: color, wash: (0.16, 0.03), border: 0.5, lineWidth: 0.75, cornerRadius: 3)
                .frame(width: 96, height: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(lines.map { $0 ?? "No reading yet" }.joined(separator: ", "))
    }
}

/// Settings › Mini monitor.
struct MiniMonitorSettings: View {
    @Setting(Settings.miniMonitorShown) private var shown: Bool
    @Setting(Settings.miniMonitorLevel) private var level: MiniMonitorLevel
    @Setting(Settings.miniMonitorCorner) private var corner: ScreenCorner
    @Setting(Settings.miniMonitorOpacity) private var opacity: Double
    @Setting(Settings.miniMonitorSolidUnderPointer) private var solidUnderPointer: Bool
    @Setting(Settings.miniMonitorMeters) private var meters: MiniMonitorMeters

    var body: some View {
        Section("Mini monitor") {
            Toggle("Show the mini monitor", isOn: $shown)
            Picker("Position", selection: $level) {
                ForEach(MiniMonitorLevel.allCases) { Text($0.title).tag($0) }
            }
            Picker("Corner", selection: $corner) {
                ForEach(ScreenCorner.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Opacity") {
                Slider(value: $opacity, in: 0.3...1)
                    .accessibilityValue(Format.percent(opacity))
            }
            Toggle("Full strength under the pointer", isOn: $solidUnderPointer)
            LabeledContent("Meters") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(MiniMonitorMeter.allCases) { meter in
                        Toggle(meter.title, isOn: Binding {
                            meters.contains(meter)
                        } set: { _ in
                            meters.toggle(meter)
                        })
                        // The last one can't be turned off.
                        .disabled(meters.contains(meter) && meters.shown.count == 1)
                    }
                }
            }
            Text("A small window with the last minute of each meter. Drag it to any corner of any display; "
                + "double-click it to open OpenTaskManager, or Control-click it for its options. "
                + "GPU and Power show where this Mac reports them. Shown on its own, it samples no faster than "
                + "once a second and skips the main window's process details.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
