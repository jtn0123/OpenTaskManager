import OTMKit
import SwiftUI

struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    static let bytesAxis: (Double) -> String = { Format.bytes(max($0, 0)) }
    static let rateAxis: (Double) -> String = { Format.bytesPerSecond(max($0, 0)) }
    private static var pageIn: Color { Theme.pageIn }
    private static var pageOut: Color { Theme.pageOut }

    var body: some View {
        let memory = snapshot.memory
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Memory", subtitle: "\(Format.bytes(memory.physical)) · \(memory.pressure.rawValue) pressure")
            stats(memory)
            composition(memory)
            FillGrid(minimum: 280) {
                pressure(memory)
                swap(memory)
            }
            FillGrid(minimum: 280) {
                paging(memory)
                compressor(memory)
            }
            byApp()
            TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: model.appGroups,
                        metric: { Double($0.memory) }, format: { Format.bytes($0.memory) }, column: .memory)
        }
    }

    private func composition(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail
        return ChartCard(
            title: "What's in memory",
            trailing: "\(Format.bytes(memory.used)) used of \(Format.bytes(memory.physical))",
            tint: Theme.memory,
            legend: [
                LegendItem(name: "Wired (kernel)", color: Theme.wired, value: Format.bytes(memory.wired)),
                LegendItem(name: "App", color: Theme.memory, value: Format.bytes(memory.app)),
                LegendItem(name: "Compressed", color: Theme.compressed, value: Format.bytes(memory.compressed)),
                LegendItem(name: "Cached files", color: Theme.cached, value: Format.bytes(memory.cached)),
                LegendItem(name: "Free", color: Theme.other.opacity(0.35), value: Format.bytes(memory.free)),
            ],
            offersFit: true
        ) {
            GraphView(
                series: [
                    GraphSeries(values: history.wired.values, color: Theme.wired),
                    GraphSeries(values: history.app.values, color: Theme.memory),
                    GraphSeries(values: history.compressed.values, color: Theme.compressed),
                    GraphSeries(values: history.cached.values, color: Theme.cached),
                ],
                maxValue: Double(memory.physical), glows: true, stacked: true, axis: Self.bytesAxis, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.primary, tint: Theme.memory)
        }
    }

    /// The pressure level and the plotted figure. Available memory is the
    /// strip's to show: beside "Pressure 21%" a "79% available" reads as the
    /// same measure twice.
    private func pressure(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail.pressure
        let color = Self.color(memory.pressure)
        let now = history.values.last.map { Format.percent($0) }
        return ChartCard(title: "Pressure", trailing: memory.pressure.rawValue.capitalized + (now.map { " · pressure \($0)" } ?? ""),
                         tint: color, legend: [
            LegendItem(name: "Pressure", color: color, value: now ?? "—"),
        ]) {
            GraphView(series: [GraphSeries(values: history.values, color: color)], maxValue: 1, glows: true,
                      axis: { Format.percent($0) }, cornerRadius: 8)
                .chartFrame(height: DetailGraph.compact, tint: color)
        }
    }

    private func swap(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail
        return ChartCard(title: "Swap and compression", trailing: "", tint: Theme.swap, legend: [
            LegendItem(name: "Swap used", color: Theme.swap,
                       value: memory.swapTotal > 0 ? "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))" : "None"),
            LegendItem(name: "Compressed", color: Theme.compressed, value: Format.bytes(memory.compressed)),
        ]) {
            GraphView(
                series: [
                    GraphSeries(values: history.swapUsed.values, color: Theme.swap),
                    GraphSeries(values: history.compressed.values, color: Theme.compressed, fill: false, dashed: true),
                ],
                glows: true, minimumCeiling: 1_073_741_824, axis: Self.bytesAxis, axisUnits: .binaryBytes, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.compact, tint: Theme.swap)
        }
    }

    /// Pages read from and written to disk: mapped files and swap.
    private func paging(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail
        return ChartCard(title: "Paging", trailing: "", tint: Self.pageIn, legend: [
            LegendItem(name: "Page-ins", color: Self.pageIn, value: Format.bytesPerSecond(memory.pageInRate)),
            LegendItem(name: "Page-outs", color: Self.pageOut, value: Format.bytesPerSecond(memory.pageOutRate)),
            LegendItem(name: "Swap-ins", color: Theme.swap, value: Format.bytesPerSecond(memory.swapInRate)),
            LegendItem(name: "Swap-outs", color: Theme.compressed, value: Format.bytesPerSecond(memory.swapOutRate)),
        ]) {
            GraphView(
                series: [
                    GraphSeries(values: history.pageIns.values, color: Self.pageIn),
                    GraphSeries(values: history.pageOuts.values, color: Self.pageOut),
                    GraphSeries(values: history.swapIns.values, color: Theme.swap, fill: false, dashed: true),
                    GraphSeries(values: history.swapOuts.values, color: Theme.compressed, fill: false, dashed: true),
                ],
                glows: true, minimumCeiling: 1_048_576, axis: Self.rateAxis, axisUnits: .binaryBytes, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.compact, tint: Self.pageIn)
        }
    }

    /// Pages squeezed into and pulled out of the compressor.
    private func compressor(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail
        return ChartCard(title: "Compressor", trailing: "", tint: Theme.compressed, legend: [
            LegendItem(name: "Compressing", color: Theme.compressed, value: Format.bytesPerSecond(memory.compressionRate)),
            LegendItem(name: "Decompressing", color: Theme.cached, value: Format.bytesPerSecond(memory.decompressionRate)),
        ]) {
            GraphView(
                series: [
                    GraphSeries(values: history.compressions.values, color: Theme.compressed),
                    GraphSeries(values: history.decompressions.values, color: Theme.cached),
                ],
                glows: true, minimumCeiling: 1_048_576, axis: Self.rateAxis, axisUnits: .binaryBytes, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.compact, tint: Theme.compressed)
        }
    }

    private func byApp() -> some View {
        let apps = model.topApps(by: .memory, count: 6)
        let other = GraphMath.remainder(of: model.processMemoryHistory.values, minus: apps.map(\.values))
        let colors = Theme.appColors(for: apps.map(\.id), in: "memory")
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: colors[$0]) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map { LegendItem(name: $1.name, color: colors[$0], value: Format.bytes($1.current), icon: $1.icon) }
            + [LegendItem(name: "Everything else", color: Theme.other, value: Format.bytes(other.last ?? 0))]
        // Over the same window as the graphs above, so they line up.
        return ChartCard(title: "Memory by app", trailing: "", tint: Theme.memory, legend: legend) {
            GraphView(series: series, glows: true, stacked: true, axis: Self.bytesAxis, axisUnits: .binaryBytes, cornerRadius: 8)
                .chartFrame(height: DetailGraph.secondary, tint: Theme.memory)
        }
    }

    /// The headline figures. The composition's legend has the rest.
    private func stats(_ memory: MemorySample) -> some View {
        MetricStrip(tint: Theme.memory) {
            Stat(label: "In use", number: Double(memory.used), color: Theme.memory, format: Self.bytesAxis)
            Stat(label: "Available, incl. cache", number: Double(memory.free + memory.cached), format: Self.bytesAxis)
                .help("Free memory plus cached files. macOS drops cached files as soon as apps need the room, so they count as available.")
            Stat(label: "Pressure", value: memory.pressure.rawValue.capitalized, color: Self.color(memory.pressure))
            Stat(label: "Swap used", number: Double(memory.swapUsed), format: Self.bytesAxis)
            Stat(label: "Page-ins since boot", value: memory.pageIns.formatted())
        }
    }

    private static func color(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}
