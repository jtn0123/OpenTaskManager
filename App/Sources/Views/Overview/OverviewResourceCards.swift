import OTMKit
import SwiftUI

// The Overview's resource cards: each reads the model itself, so a tick
// re-evaluates the cards and not the page around them.

/// The whole CPU's load, with the kernel's share of it under it, on the CPU
/// graphs' shared scale (`CPUGraphScale`), and the chip's temperature where
/// this Mac reports it.
struct CPUGraphCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.graphWindow) private var window
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto
    /// The auto-scaled graph's bound, held between samples.
    @State private var bounds = AutoScaleBounds()
    var chartHeight: CGFloat

    var body: some View {
        let cpu = model.snapshot?.cpu ?? .zero
        let total = model.cpuHistory.values
        let top = scale == .auto ? bounds.bound("cpu", peak: AutoScaleBounds.peak(total, capacity: window)) : 1
        let temperature = model.sensors?.hottest(.chip).map { " · \(Format.celsius($0))" } ?? ""
        // The kernel's colour, as wired memory's "Wired (kernel)" on Memory.
        let kernel = Theme.wired
        OverviewGraphCard(
            title: "CPU", symbol: "cpu", tint: Theme.cpu, glow: cpu.usage,
            headline: .init(value: cpu.usage, format: { Format.percent($0) }, widest: "100%"),
            facts: "\(model.topology.logicalCores) cores · load \(Format.fixed(cpu.loadAverage.first ?? 0, 2))" + temperature,
            keys: [
                ChartKey(name: "All", color: Theme.cpu, help: "How busy the whole CPU is: apps and the system together"),
                ChartKey(name: "System", color: kernel, mark: .dashed, value: Format.percent(cpu.system),
                         help: "The part of it the kernel spends working on the system's behalf"),
            ],
            chartHeight: chartHeight
        ) {
            GraphView(
                series: [
                    GraphSeries(values: total, color: Theme.cpu),
                    // Unfilled: its fill over the total's would tint the whole area.
                    GraphSeries(values: model.cpuSystemHistory.values, color: kernel, fill: false, dashed: true),
                ],
                maxValue: top, glows: true, axis: CPUGraphScale.axisLabel,
                axisNote: scale == .auto ? CPUGraphScale.autoNote : nil, cornerRadius: 8
            )
        }
    }
}

/// Memory in use, with the kernel's memory pressure beside it, both as a
/// share of the Mac's memory.
struct MemoryGraphCard: View {
    private static let pressureColors: [MemoryPressure: Color] = [
        .normal: Theme.data(.systemGreen), .warning: Theme.data(.systemOrange), .critical: Theme.data(.systemRed),
    ]

    @Environment(AppModel.self) private var model
    var chartHeight: CGFloat

    var body: some View {
        if let memory = model.snapshot?.memory {
            let color: Color = switch memory.pressure {
            case .normal: Theme.memory
            case .warning: .orange
            case .critical: .red
            }
            let pressure = model.memoryDetail.pressure
            let pressureColor = Self.pressureColors[memory.pressure] ?? Theme.memory
            OverviewGraphCard(
                title: "Memory", symbol: "memorychip", tint: color, glow: memory.usedFraction,
                headline: .init(value: memory.usedFraction, format: { Format.percent($0) }, widest: "100%"),
                facts: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical))",
                keys: [
                    ChartKey(name: "Used", color: color, help: "Memory in use: apps, wired and compressed"),
                    ChartKey(name: "Pressure", color: pressureColor, mark: .dashed,
                             value: "\(pressure.last.map { Format.percent($0) } ?? "—") · \(memory.pressure.rawValue)",
                             help: "How hard macOS is working to find free memory, from how much it says is available"),
                ],
                chartHeight: chartHeight
            ) {
                GraphView(
                    series: [
                        GraphSeries(values: model.memoryHistory.values, color: color),
                        GraphSeries(values: pressure.values, color: pressureColor, fill: false, dashed: true),
                    ],
                    maxValue: 1, glows: true, axis: { Format.percent($0) }, cornerRadius: 8
                )
            }
        }
    }
}

/// How busy a GPU that reports it is.
struct GPUGraphCard: View {
    @Environment(AppModel.self) private var model
    var gpu: GPUSample
    var busy: Double
    var chartHeight: CGFloat

    var body: some View {
        let facts = [gpu.tellingName, gpu.coreCount.map { "\($0) cores" }, gpu.memoryInUse.map { "\(Format.bytes($0)) in use" }]
        OverviewGraphCard(
            title: "GPU", symbol: "cpu.fill", tint: Theme.gpu, glow: busy,
            headline: .init(value: busy, format: { Format.percent($0) }, widest: "100%"),
            facts: facts.compactMap { $0 }.joined(separator: " · "),
            chartHeight: chartHeight
        ) {
            GraphView(series: [GraphSeries(values: model.gpuHistory[gpu.id]?.values ?? [], color: Theme.gpu)],
                      maxValue: 1, glows: true, axis: { Format.percent($0) }, cornerRadius: 8)
        }
    }
}

/// The whole Mac's power, stacked by part of the chip where this Mac says,
/// with the rest of the system (display, storage, radios) on top.
struct PowerGraphCard: View {
    @Environment(AppModel.self) private var model
    var power: PowerSample
    var chartHeight: CGFloat

    var body: some View {
        let watts = power.systemWatts ?? power.components?.total ?? 0
        // Glows against the most this Mac has drawn, so it reads as "how hard
        // is it working" whether it's an Air or a Studio.
        let ceiling = max(model.peakSystemWatts, 20)
        let source = power.battery.map { "Battery \($0.percent)%" + ($0.isPluggedIn ? ", plugged in" : "") } ?? "AC power"
        let thermal = "Thermal \(power.thermalState.rawValue)" + (model.sensors?.hottest(.chip).map { " · \(Format.celsius($0))" } ?? "")
        let bands = bands(power.components)
        OverviewGraphCard(
            title: "Power", symbol: "bolt.fill", tint: Theme.power, glow: watts / ceiling,
            headline: .init(value: watts, format: { "\(Format.fixed($0, $0 < 10 ? 1 : 0)) W" }, widest: "188 W"),
            facts: "\(source) · \(thermal)",
            keys: bands.count > 1 ? bands.map(\.key) : [],
            chartHeight: chartHeight
        ) {
            if bands.count > 1 {
                GraphView(series: bands.map(\.series), glows: true, stacked: true, minimumCeiling: 5, axis: Format.watts, cornerRadius: 8)
            } else {
                GraphView(series: [GraphSeries(values: model.powerHistory.values, color: Theme.power)],
                          glows: true, minimumCeiling: 5, axis: Format.watts, cornerRadius: 8)
            }
        }
    }

    /// The measured parts of the chip, then the rest of the system, which
    /// takes the stack's top to the whole Mac's figure. Parts this Mac
    /// doesn't measure would only add flat bands, so they're left out.
    private func bands(_ components: PowerComponents?) -> [(series: GraphSeries, key: ChartKey)] {
        guard let components else { return [] }
        let history = model.powerDetail
        let parts = [
            Part(component: .cpu, name: "CPU", color: Theme.cpu, history: history.cpu),
            Part(component: .gpu, name: "GPU", color: Theme.gpu, history: history.gpu),
            Part(component: .ane, name: "Neural Engine", color: Theme.neuralEngine, history: history.ane),
            Part(component: .dram, name: "Memory", color: Theme.dram, history: history.dram),
        ]
        let measured = parts.filter { components.isMeasured($0.component) }.map { part in
            (series: GraphSeries(values: part.history.values, color: part.color),
             key: ChartKey(name: part.name, color: part.color, mark: .band, value: Format.watts(components.watts(part.component) ?? 0)))
        }
        let rest = history.rest
        return measured + [(series: GraphSeries(values: rest.values, color: Theme.restOfSystem),
                            key: ChartKey(name: "Rest", color: Theme.restOfSystem, mark: .band, value: Format.watts(rest.last ?? 0),
                                          help: "The rest of the Mac: display, storage, radios, fans and power conversion"))]
    }

    private struct Part {
        var component: PowerComponent
        var name: String
        var color: Color
        var history: History<Double>
    }
}
