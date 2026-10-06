import OTMKit
import SwiftUI

struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    static let bytesAxis: (Double) -> String = { Format.bytes(max($0, 0)) }
    static let rateAxis: (Double) -> String = { Format.bytesPerSecond(max($0, 0)) }
    private static let pageIn = Color(red: 0.32, green: 0.70, blue: 0.86)
    private static let pageOut = Color(red: 0.64, green: 0.42, blue: 0.96)

    var body: some View {
        let memory = snapshot.memory
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Memory", subtitle: "\(Format.bytes(memory.physical)) · \(memory.pressure.rawValue) pressure")
            composition(memory)
            HStack(alignment: .top, spacing: 16) {
                pressure(memory)
                swap(memory)
            }
            HStack(alignment: .top, spacing: 16) {
                paging(memory)
                compressor(memory)
            }
            byApp()
            stats(memory)
            TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: model.appGroups,
                        metric: { Double($0.memory) }, format: { Format.bytes($0.memory) })
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
            ]
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
            .chartFrame(height: 220, tint: Theme.memory)
        }
    }

    private func pressure(_ memory: MemorySample) -> some View {
        let history = model.memoryDetail.pressure
        let color: Color = switch memory.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
        let available = memory.availablePercent.map { " · \($0)% available" } ?? ""
        return ChartCard(title: "Pressure", trailing: memory.pressure.rawValue.capitalized + available, tint: color, legend: [
            LegendItem(name: "Pressure", color: color, value: history.values.last.map { Format.percent($0) } ?? "—"),
        ]) {
            GraphView(series: [GraphSeries(values: history.values, color: color)], maxValue: 1, glows: true,
                      axis: { Format.percent($0) }, cornerRadius: 8)
                .chartFrame(height: 130, tint: color)
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
            .chartFrame(height: 130, tint: Theme.swap)
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
            .chartFrame(height: 130, tint: Self.pageIn)
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
            .chartFrame(height: 130, tint: Theme.compressed)
        }
    }

    private func byApp() -> some View {
        let apps = model.topApps(by: { Double($0.memory) }, count: 6)
        let other = AppModel.remainder(of: model.processMemoryHistory.values, minus: apps.map(\.values))
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: Theme.series($0)) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map { LegendItem(name: $1.name, color: Theme.series($0), value: Format.bytes($1.current), icon: $1.icon) }
            + [LegendItem(name: "Everything else", color: Theme.other, value: Format.bytes(other.last ?? 0))]
        return ChartCard(title: "Memory by app", trailing: "last 2 minutes", tint: Theme.memory, legend: legend) {
            GraphView(series: series, capacity: AppModel.processHistoryCapacity - 2, glows: true, stacked: true,
                      axis: Self.bytesAxis, axisUnits: .binaryBytes, cornerRadius: 8)
                .chartFrame(height: 200, tint: Theme.memory)
        }
    }

    private func stats(_ memory: MemorySample) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 14) {
            Stat(label: "In use", number: Double(memory.used), color: Theme.memory, format: Self.bytesAxis)
            Stat(label: "Available", number: Double(memory.free + memory.cached), format: Self.bytesAxis)
            Stat(label: "App", number: Double(memory.app), format: Self.bytesAxis)
            Stat(label: "Wired", number: Double(memory.wired), format: Self.bytesAxis)
            Stat(label: "Compressed", number: Double(memory.compressed), format: Self.bytesAxis)
            Stat(label: "Cached files", number: Double(memory.cached), format: Self.bytesAxis)
            Stat(label: "Swap used", number: Double(memory.swapUsed), format: Self.bytesAxis)
            Stat(label: "Page-ins since boot", value: memory.pageIns.formatted())
        }
    }
}
