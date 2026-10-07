import OTMKit
import SwiftUI

struct GPUDetail: View {
    @Environment(AppModel.self) private var model
    var gpu: GPUSample
    var snapshot: SystemSnapshot

    private static let renderer = Theme.data(0.58, 0.92, 0.96)
    private static let tiler = Theme.data(0.36, 0.62, 1.00)
    private static let clock = Theme.data(0.45, 0.95, 0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "GPU", subtitle: subtitle)
            stats()
            // A paravirtual GPU only reports memory. The strip says so, and the
            // graphs it can draw move up rather than sit under a flat 0%.
            if let busy = gpu.deviceUtilization { utilization(busy) }
            byApp()
            FillGrid(minimum: 280) {
                if gpu.frequencyMHz != nil || gpu.activeResidency != nil { clock() }
                if let memory = gpu.memoryInUse { memoryCard(memory) }
            }
            TopAppsCard(title: "GPU", symbol: "cpu.fill", color: Theme.gpu, groups: model.appGroups,
                        metric: \.gpuFraction, format: { Format.percent($0.gpuFraction, digits: 1) }, minimum: 0.0005)
            GPUBenchmarkCard()
                .equatable()
        }
    }

    private var subtitle: String {
        gpu.coreCount.map { "\(gpu.name) · \($0) cores" } ?? gpu.name
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
        return ChartCard(title: "Utilization", trailing: Format.percent(busy), tint: Theme.gpu, legend: legend) {
            GraphView(
                series: [
                    GraphSeries(values: model.gpuHistory[gpu.id]?.values ?? [], color: Theme.gpu),
                    GraphSeries(values: detail.renderer.values, color: Self.renderer, fill: false),
                    GraphSeries(values: detail.tiler.values, color: Self.tiler, fill: false, dashed: true),
                ],
                maxValue: 1, glows: true, axis: { Format.percent($0) }, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.primary, tint: Theme.gpu)
        }
    }

    private func byApp() -> some View {
        let apps = model.topApps(by: \.gpuFraction, count: 5)
        let other = AppModel.remainder(of: model.processGPUHistory.values, minus: apps.map(\.values))
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: Theme.series($0)) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: Theme.series($0), value: Format.percent($1.current, digits: 1), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.percent(other.last ?? 0, digits: 1))]
        return ChartCard(title: "GPU time by app", trailing: "share of GPU time", tint: Theme.gpu, legend: legend,
                         span: AppModel.processHistoryCapacity - 2) {
            GraphView(series: series, capacity: AppModel.processHistoryCapacity - 2, glows: true, stacked: true,
                      minimumCeiling: 0.05, maximumCeiling: 1, axis: { Format.percent($0) }, cornerRadius: 8)
                .chartFrame(height: DetailGraph.secondary, tint: Theme.gpu)
        }
    }

    private func clock() -> some View {
        let history = model.gpuDetail[gpu.id]?.frequency.values ?? []
        var legend = [LegendItem(name: "Clock", color: Self.clock, value: gpu.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "Idle")]
        if let active = gpu.activeResidency {
            legend.append(LegendItem(name: "Powered on", color: Theme.gpu, value: Format.percent(active)))
        }
        if let watts = snapshot.power.components?.watts(.gpu) {
            legend.append(LegendItem(name: "Power", color: Theme.power, value: Format.watts(watts)))
        }
        return ChartCard(title: "Clock speed", trailing: "average while powered on", tint: Self.clock, legend: legend) {
            GraphView(series: [GraphSeries(values: history, color: Self.clock)], glows: true, minimumCeiling: 500,
                      axis: { Format.frequency(megahertz: $0) }, cornerRadius: 8)
                .chartFrame(height: DetailGraph.compact, tint: Self.clock)
        }
    }

    private func memoryCard(_ inUse: UInt64) -> some View {
        let history = model.gpuDetail[gpu.id]?.memoryInUse.values ?? []
        return ChartCard(title: "GPU memory in use", trailing: Format.bytes(inUse), tint: Theme.gpu) {
            GraphView(series: [GraphSeries(values: history, color: Theme.gpu)], glows: true, minimumCeiling: 268_435_456,
                      axis: MemoryDetail.bytesAxis, axisUnits: .binaryBytes, cornerRadius: 8)
                .chartFrame(height: DetailGraph.compact, tint: Theme.gpu)
        }
    }

    private func stats() -> some View {
        MetricStrip(tint: Theme.gpu) {
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
            if gpu.deviceUtilization == nil {
                CapabilityNote(label: "Utilization", text: Unavailable.gpuUtilizationShort,
                               detail: Unavailable.gpuUtilizationDetail + " GPU time by app and memory in use are measured.")
            }
        }
    }
}
