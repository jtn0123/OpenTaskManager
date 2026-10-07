import OTMKit
import SwiftUI

/// The figures at the moment the pointer rests on (or the latest), and the
/// apps that were busiest then, read from the recording for that stretch.
struct HistoryMomentPanel: View {
    @Environment(AppModel.self) private var model
    let scrubber: HistoryScrubber
    let points: [HistoryPoint]
    /// Seconds each point averages.
    let bucket: TimeInterval
    @State private var topCPU: [HistoryApp] = []
    @State private var topMemory: [HistoryApp] = []

    var body: some View {
        let point = nearest(to: scrubber.time)
        Card(tint: Theme.cpu) {
            if let point {
                heading(point)
                Divider()
                figures(point.values)
                Divider()
                apps
            } else {
                Text("Nothing recorded yet").font(.headline)
                Text("Hover over a graph to see that moment here.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: point?.time) {
            guard let point, let recorder = model.recorder else { return }
            let records = (try? await recorder.records(from: point.time.addingTimeInterval(-bucket), to: point.time)) ?? []
            let top = HistoryRecord.topApps(in: records, count: 5)
            topCPU = top.cpu
            topMemory = top.memory
        }
    }

    private func heading(_ point: HistoryPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(scrubber.time == nil ? "Latest" : moment(point.time)).font(.headline)
                Spacer()
                if scrubber.time != nil {
                    Button("Latest") { scrubber.time = nil }
                        .controlSize(.small)
                }
            }
            Text(bucket <= FlightRecorder.span ? "Average of \(Int(FlightRecorder.span)) seconds"
                 : "Average of \(Format.timeSpan(bucket)) up to \(point.time.formatted(date: .omitted, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

    private func moment(_ time: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(time)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return time.formatted(style)
    }

    /// The point closest to `time`, or the latest when there's no time.
    private func nearest(to time: Date?) -> HistoryPoint? {
        guard let time else { return points.last }
        return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
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
