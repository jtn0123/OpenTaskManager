import OTMKit
import SwiftUI

struct GPUDetail: View {
    @Environment(AppModel.self) private var model
    var gpu: GPUSample
    var snapshot: SystemSnapshot

    private static var clock: Color { Theme.gpuClock }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Its title, level bar and main graph: utilization, or memory in use
            // where a paravirtual GPU reports nothing else, never a flat 0%.
            GPUHero(gpu: gpu, snapshot: snapshot)
            byApp()
            FillGrid(minimum: 280) {
                if gpu.frequencyMHz != nil || gpu.activeResidency != nil { clock() }
                // Where utilization isn't reported, memory in use is the main graph.
                if gpu.deviceUtilization != nil, let memory = gpu.memoryInUse { memoryCard(memory) }
            }
            TopAppsCard(title: "GPU", symbol: "cpu.fill", color: Theme.gpu, groups: model.appGroups,
                        metric: \.gpuFraction, format: { Format.percent($0.gpuFraction, digits: 1) }, column: .gpu)
            GPUBenchmarkCard()
                .equatable()
        }
    }

    private func byApp() -> some View {
        let apps = model.topApps(by: .gpu, count: 5)
        let other = GraphMath.remainder(of: model.processGPUHistory.values, minus: apps.map(\.values))
        let colors = Theme.appColors(for: apps.map(\.id), in: "gpu")
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: colors[$0]) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: colors[$0], value: Format.percent($1.current, digits: 1), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.percent(other.last ?? 0, digits: 1))]
        // Over the same window as the graphs around it, so they line up.
        return ChartCard(title: "GPU time by app", trailing: "share of GPU time", tint: Theme.gpu, legend: legend) {
            GraphView(series: series, glows: true, stacked: true,
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

}
