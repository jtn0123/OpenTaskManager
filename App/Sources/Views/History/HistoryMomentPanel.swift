import OTMKit
import SwiftUI

/// The figures at the moment picked on the graphs (previewed under the
/// pointer, pinned by a click, or else the latest), and the apps that were
/// busiest then, read from the recording for that stretch.
struct HistoryMomentPanel: View {
    let scrubber: HistoryScrubber
    let points: [HistoryPoint]
    /// Seconds each point averages.
    let bucket: TimeInterval

    var body: some View {
        let point = scrubber.point(in: points)
        Card(tint: Theme.cpu) {
            if let point {
                heading(point)
                Divider()
                HistoryMomentDetails(point: point, bucket: bucket)
            } else {
                Text("Nothing recorded yet").font(.headline)
                Text("Click or drag on a graph to pick a moment and see it here.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether the panel follows the pointer, a pinned moment or the latest,
    /// and the moment's time, large.
    private func heading(_ point: HistoryPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                HistoryMomentBadge(scrubber: scrubber)
                Spacer()
                if scrubber.pinned != nil {
                    HistoryReturnButton(scrubber: scrubber, title: "Return to latest")
                }
            }
            Text(HistoryMoment.label(point.time, bucket: bucket))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(bucket <= FlightRecorder.span ? "Average of \(Int(FlightRecorder.span)) seconds"
                 : "Average of the \(Format.timeSpan(bucket)) up to this time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let hint = scrubber.hint {
                Text(hint).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The moment panel's place in a narrow window, over the charts beside the
/// rail: the moment's time and main figures in a band, with every figure
/// and the busiest apps a click away. Its height doesn't change from one
/// moment to the next, so the charts under the pointer never shift.
struct HistoryMomentSummary: View {
    let scrubber: HistoryScrubber
    let points: [HistoryPoint]
    /// Seconds each point averages.
    let bucket: TimeInterval
    /// Wide enough for "Disk write" and "99.9 KB/s".
    private static let figureWidth = 76.0

    @State private var showsDetails = false
    @State private var gridWidth: CGFloat = 0

    private struct Figure: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let value: String
    }

    var body: some View {
        let point = scrubber.point(in: points)
        Card(tint: Theme.cpu) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HistoryMomentBadge(scrubber: scrubber)
                Text(point.map { HistoryMoment.label($0.time, bucket: bucket) } ?? "—")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
                Text(bucket <= FlightRecorder.span ? "\(Int(FlightRecorder.span)) s average" : "\(Format.timeSpan(bucket)) average")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if scrubber.pinned != nil {
                    HistoryReturnButton(scrubber: scrubber, title: "Latest")
                }
                Button {
                    showsDetails.toggle()
                } label: {
                    Label("Details", systemImage: "chevron.down")
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(point == nil)
                .help("Every figure at this moment, and the apps that were busiest")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    if let point {
                        HistoryMomentDetails(point: point, bucket: bucket)
                            .padding(16)
                            .frame(width: 300)
                    }
                }
            }
            let figures = figures(point?.values)
            // As many columns as fit, spread evenly: seven figures that fit
            // six across take rows of four and three, not six and one.
            let columns = gridWidth > 0
                ? GridMath.rows(count: figures.count, width: Double(gridWidth), minimum: Self.figureWidth, spacing: 12).first?.count ?? 1
                : figures.count
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: max(columns, 1)),
                      alignment: .leading, spacing: 8) {
                ForEach(figures) { figure in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle().fill(figure.color).frame(width: 6, height: 6)
                            Text(figure.name).lineLimit(1)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Text(figure.value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        }
        .help(scrubber.hint ?? "")
    }

    /// The figures every chart has, plus GPU, power and the chip's
    /// temperature when the range recorded them, so the set (and the
    /// summary's height) stays put as the moment moves.
    private func figures(_ values: HistoryValues?) -> [Figure] {
        func has(_ value: (HistoryValues) -> Double?) -> Bool { points.contains { value($0.values) != nil } }
        func show(_ value: Double?, _ format: (Double) -> String) -> String { value.map(format) ?? "—" }
        var list = [
            Figure(name: "CPU", color: Theme.cpu, value: show(values?.cpu) { Format.percent($0) }),
            Figure(name: "Memory", color: Theme.memory, value: show(values?.memory) { Format.percent($0) }),
        ]
        if has({ $0.gpu }) {
            list.append(Figure(name: "GPU", color: Theme.gpu, value: show(values?.gpu) { Format.percent($0) }))
        }
        if has({ $0.systemWatts }) {
            list.append(Figure(name: "Power", color: Theme.power, value: show(values?.systemWatts, Format.watts)))
        }
        list += [
            Figure(name: "Disk read", color: Theme.disk, value: show(values?.diskRead, Format.bytesPerSecond)),
            Figure(name: "Disk write", color: Theme.diskSecondary, value: show(values?.diskWrite, Format.bytesPerSecond)),
            Figure(name: "Received", color: Theme.network, value: show(values?.networkIn, Format.bitsPerSecond)),
            Figure(name: "Sent", color: Theme.networkSecondary, value: show(values?.networkOut, Format.bitsPerSecond)),
        ]
        if has({ $0.chipCelsius }) {
            list.append(Figure(name: "Chip", color: Theme.thermal, value: show(values?.chipCelsius, Format.celsius)))
        }
        return list
    }
}

/// Every figure at one moment, and the apps that were busiest then, read
/// from the recording for that stretch: the body of the side panel, and
/// the narrow summary's details.
struct HistoryMomentDetails: View {
    @Environment(AppModel.self) private var model
    let point: HistoryPoint
    /// Seconds each point averages.
    let bucket: TimeInterval
    @State private var topCPU: [HistoryApp] = []
    @State private var topMemory: [HistoryApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            figures(point.values)
            Divider()
            apps
        }
        .task(id: point.time) {
            guard let recorder = model.recorder else { return }
            let records = (try? await recorder.records(from: point.time.addingTimeInterval(-bucket), to: point.time)) ?? []
            let top = HistoryRecord.topApps(in: records, count: 5)
            topCPU = top.cpu
            topMemory = top.memory
        }
    }

    private func figures(_ values: HistoryValues) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("CPU", Theme.cpu, Format.percent(values.cpu), detail: "peak \(Format.percent(values.cpuPeak))")
            row("Memory", Theme.memory, Format.percent(values.memory), detail: "pressure \(Format.percent(values.memoryPressure))")
            if values.swapUsed > 0 {
                row("Swap", Theme.swap, Format.bytes(values.swapUsed))
            }
            if let gpu = values.gpu {
                row("GPU", Theme.gpu, Format.percent(gpu))
            }
            if let watts = values.systemWatts {
                let parts = [values.cpuWatts.map { "CPU " + Format.watts($0) }, values.gpuWatts.map { "GPU " + Format.watts($0) }]
                row("Power", Theme.power, Format.watts(watts), detail: parts.compactMap { $0 }.joined(separator: " · "))
            }
            row("Disk read", Theme.disk, Format.bytesPerSecond(values.diskRead))
            row("Disk write", Theme.diskSecondary, Format.bytesPerSecond(values.diskWrite))
            row("Received", Theme.network, Format.bitsPerSecond(values.networkIn))
            row("Sent", Theme.networkSecondary, Format.bitsPerSecond(values.networkOut))
            if let celsius = values.chipCelsius {
                row("Chip", Theme.thermal, Format.celsius(celsius))
            }
        }
        .font(.callout)
    }

    private func row(_ name: String, _ color: Color, _ value: String, detail: String = "") -> some View {
        GridRow(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(value).fontWeight(.medium).monospacedDigit()
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Busiest apps").font(.headline)
            // Leave out apps whose share would read 0.0%.
            AppBars(title: "CPU", apps: topCPU.filter { model.cpuScale.value($0.value) >= 0.05 }, color: Theme.cpu,
                    format: model.cpuScale.format)
            AppBars(title: "Memory", apps: topMemory, color: Theme.memory) { Format.bytes($0) }
        }
    }
}

/// "Latest", "Pinned" or "Preview": whether the moment shown follows the
/// recording, a click, or the pointer.
private struct HistoryMomentBadge: View {
    let scrubber: HistoryScrubber

    var body: some View {
        let (state, color): (String, Color) = scrubber.hovered != nil ? ("Preview", .secondary)
            : scrubber.pinned != nil ? ("Pinned", .accentColor) : ("Latest", .green)
        Text(state.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// Unpins the moment, so the panel follows the latest again. Esc does the same.
private struct HistoryReturnButton: View {
    let scrubber: HistoryScrubber
    let title: String

    var body: some View {
        Button {
            scrubber.pinned = nil
        } label: {
            Label(title, systemImage: "arrow.uturn.forward")
        }
        .controlSize(.small)
        .fixedSize()
        .keyboardShortcut(.cancelAction)
        .help("Unpin the moment and follow the latest again (Esc)")
    }
}

private extension HistoryScrubber {
    /// How to pick a moment, while none is pinned.
    var hint: String? {
        guard pinned == nil else { return nil }
        return hovered == nil ? "Click or drag on a graph or the timeline to pin a moment." : "Click to pin this moment."
    }
}

/// A short ranked list of apps, each with a bar scaled to the busiest.
private struct AppBars: View {
    let title: String
    let apps: [HistoryApp]
    let color: Color
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("—").font(.callout).foregroundStyle(.tertiary)
            }
            let top = apps.first?.value ?? 1
            ForEach(apps, id: \.name) { app in
                HStack(spacing: 8) {
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(format(app.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(alignment: .leading) {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * min(app.value / max(top, 1e-9), 1))
                    }
                }
            }
        }
    }
}
