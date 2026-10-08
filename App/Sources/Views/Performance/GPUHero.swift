import OTMKit
import SwiftUI

/// The GPU page's title, level bar and main card. Its main graph is how busy
/// the GPU is; a GPU whose driver doesn't say (a virtual machine's) graphs
/// its memory in use instead, with the bar left dim and a note saying why,
/// never a flat 0%.
struct GPUHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.detailPaneHeight) private var pane
    var gpu: GPUSample
    var snapshot: SystemSnapshot

    private static var renderer: Color { Theme.gpuRenderer }
    private static var tiler: Color { Theme.gpuTiler }
    /// A scale for memory in use that a few megabytes don't fill.
    private static let memoryCeiling = 268_435_456.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceHeader(title: "GPU", subtitle: subtitle, level: level)
            if let busy = gpu.deviceUtilization {
                utilization(busy)
            } else {
                memory()
            }
        }
    }

    /// The name and cores; a paravirtual GPU's name, "GPU", would only repeat the title.
    private var subtitle: String {
        [gpu.tellingName, gpu.coreCount.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var level: LevelRow {
        if let busy = gpu.deviceUtilization {
            return LevelRow(fraction: busy, color: Theme.gpu, value: busy, caption: "busy", label: "GPU utilization")
        }
        if let memory = gpu.memoryInUse {
            return LevelRow(fraction: nil, color: Theme.gpu, value: Double(memory), format: MemoryDetail.bytesAxis,
                            caption: "memory in use", label: "GPU utilization, not reported", figureWidth: 86)
        }
        return LevelRow(fraction: nil, color: Theme.gpu, text: "—", caption: Unavailable.gpuUtilization.lowercased(),
                        label: "GPU utilization, not reported", figureWidth: 0)
    }

    private func utilization(_ busy: Double) -> some View {
        let detail = model.gpuDetail[gpu.id] ?? GPUHistory()
        var legend = [LegendItem(name: "Device", color: Theme.gpu, value: Format.percent(busy))]
        if let renderer = gpu.rendererUtilization {
            legend.append(LegendItem(name: "Renderer (shading)", color: Self.renderer, value: Format.percent(renderer)))
        }
        if let tiler = gpu.tilerUtilization {
            legend.append(LegendItem(name: "Tiler (geometry)", color: Self.tiler, value: Format.percent(tiler)))
        }
        return DeviceCard(tint: Theme.gpu, legend: legend) {
            DeviceCaption(title: "Utilization", trailing: Format.percent(busy))
        } plot: {
            GraphView(
                series: [
                    GraphSeries(values: model.gpuHistory[gpu.id]?.values ?? [], color: Theme.gpu),
                    GraphSeries(values: detail.renderer.values, color: Self.renderer, fill: false),
                    GraphSeries(values: detail.tiler.values, color: Self.tiler, fill: false, dashed: true),
                ],
                maxValue: 1, showsGrid: false, glows: true, axis: { Format.percent($0) }, cornerRadius: 8
            )
            .heroPlot(height: Hero.height(pane: pane, extra: Hero.legendLine), tint: Theme.gpu)
        } figures: {
            figures()
        }
    }

    /// Memory in use where utilization isn't reported, the one reading of
    /// its own over time such a GPU gives.
    private func memory() -> some View {
        let history = model.gpuDetail[gpu.id]?.memoryInUse.values ?? []
        let inUse = gpu.memoryInUse.map { Format.bytes($0) } ?? "—"
        return DeviceCard(tint: Theme.gpu, legend: [LegendItem(name: "Memory in use", color: Theme.gpu, value: inUse)],
                          footnote: Unavailable.gpuUtilizationDetail + " Its memory in use is graphed instead; "
                              + "GPU time by app is measured below.") {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory in use").font(.headline)
                Spacer(minLength: 8)
                Label(Unavailable.gpuUtilization, systemImage: Unavailable.symbol)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
        } plot: {
            GraphView(series: [GraphSeries(values: history, color: Theme.gpu)], showsGrid: false, glows: true,
                      minimumCeiling: Self.memoryCeiling, axis: MemoryDetail.bytesAxis, axisUnits: .binaryBytes, cornerRadius: 8)
                .heroPlot(height: Hero.height(pane: pane, extra: 2 * Hero.legendLine), tint: Theme.gpu)
        } figures: {
            figures()
        }
    }

    @ViewBuilder
    private func figures() -> some View {
        if let busy = gpu.deviceUtilization {
            Stat(label: "Utilization", number: busy, color: Theme.gpu) { Format.percent($0) }
        }
        if let renderer = gpu.rendererUtilization {
            Stat(label: "Renderer", number: renderer, color: Self.renderer) { Format.percent($0) }
        }
        if let tiler = gpu.tilerUtilization {
            Stat(label: "Tiler", number: tiler, color: Self.tiler) { Format.percent($0) }
        }
        if let frequency = gpu.frequencyMHz {
            Stat(label: "Clock", number: frequency) { Format.frequency(megahertz: $0) }
        }
        if let memory = gpu.memoryInUse {
            Stat(label: "Memory in use", number: Double(memory), format: MemoryDetail.bytesAxis)
        }
        if let watts = snapshot.power.components?.watts(.gpu) {
            Stat(label: "Power", number: watts, format: Format.watts)
        }
        if let cores = gpu.coreCount {
            Stat(label: "Cores", value: "\(cores)")
        }
        if gpu.deviceUtilization == nil {
            CapabilityNote(label: "Utilization", text: "Not reported",
                           detail: Unavailable.gpuUtilizationDetail + " GPU time by app and memory in use are measured.")
        }
    }
}
