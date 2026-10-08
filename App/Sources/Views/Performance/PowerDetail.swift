import OTMKit
import SwiftUI

struct PowerDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.detailPaneHeight) private var pane
    var snapshot: SystemSnapshot

    private static var charging: Color { Theme.charging }
    private static var discharging: Color { Theme.discharging }

    var body: some View {
        let power = snapshot.power
        VStack(alignment: .leading, spacing: 16) {
            DeviceHeader(title: "Power", subtitle: subtitle(power), level: level(power))
            if let components = power.components {
                breakdown(power, components)
            } else if let watts = power.systemWatts {
                DeviceCard(tint: Theme.power) {
                    DeviceCaption(title: "Whole-system power draw", trailing: Format.watts(watts))
                } plot: {
                    GraphView(series: [GraphSeries(values: model.powerHistory.values, color: Theme.power)], showsGrid: false,
                              glows: true, minimumCeiling: 5, axis: Format.watts, cornerRadius: 8)
                        .heroPlot(height: Hero.height(pane: pane), tint: Theme.power)
                } figures: {
                    figures(power)
                }
            } else {
                // A battery but no power reading: the figures, with no graph to head.
                MetricStrip(tint: Theme.power) { figures(power) }
            }
            if model.powerDetail.energy > 0 { energy() }
            if let clusters = power.components?.clusters, clusters.contains(where: { $0.watts != nil }) {
                clusterPower(clusters)
            }
            if power.adapter != nil || power.battery != nil { supply(power) }
            // Without per-process energy there's nothing to break down by app.
            let perApp = snapshot.measuresProcessEnergy != false
            if perApp { byApp() }
            TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: model.appGroups,
                        metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, column: .power,
                        minimum: 0.01, cutoff: "10 mW", unavailable: perApp ? nil : Unavailable.energy)
        }
    }

    private func subtitle(_ power: PowerSample) -> String {
        if let adapter = power.adapter {
            return adapter.name ?? adapter.ratedWatts.map { "\(Format.fixed($0, 0)) W adapter" } ?? "AC power"
        }
        return power.battery == nil ? "AC power" : "On battery"
    }

    /// The draw against the most this Mac has been seen to draw, or the
    /// battery's charge where there's no draw to show.
    private func level(_ power: PowerSample) -> LevelRow {
        if let watts = power.systemWatts {
            let peak = max(model.peakSystemWatts, watts)
            return LevelRow(fraction: peak > 0 ? watts / peak : 0, color: Theme.power, value: watts, format: Format.watts,
                            caption: "of \(Format.watts(peak)) highest seen", label: "Power draw", figureWidth: 76)
        }
        if let battery = power.battery {
            return LevelRow(fraction: Double(battery.percent) / 100, color: Self.charging, value: Double(battery.percent),
                            format: { "\(Int($0.rounded()))%" }, caption: "battery", label: "Battery charge")
        }
        return LevelRow(fraction: nil, color: Theme.power, text: "—", caption: "not measured", label: "Power draw")
    }

    // MARK: - Where the power goes

    private struct Part {
        let name: String
        let color: Color
        let values: [Double]
        /// nil when this Mac doesn't measure the part.
        let watts: Double?
    }

    private func parts(_ components: PowerComponents) -> [Part] {
        let history = model.powerDetail
        let cpuName = components.sources[.cpu] == .smc ? "CPU (SMC estimate)" : "CPU"
        return [
            Part(name: cpuName, color: Theme.cpu, values: history.cpu.values, watts: components.watts(.cpu)),
            Part(name: "GPU", color: Theme.gpu, values: history.gpu.values, watts: components.watts(.gpu)),
            Part(name: "Neural Engine", color: Theme.neuralEngine, values: history.ane.values, watts: components.watts(.ane)),
            Part(name: "Memory (DRAM)", color: Theme.dram, values: history.dram.values, watts: components.watts(.dram)),
        ]
    }

    private func breakdown(_ power: PowerSample, _ components: PowerComponents) -> some View {
        let chip = parts(components)
        let rest = model.powerDetail.rest.values
        let legend = chip.map { LegendItem(name: $0.name, color: $0.color, value: $0.watts.map(Format.watts) ?? "—") }
            + [LegendItem(name: "Rest of system", color: Theme.restOfSystem, value: Format.watts(rest.last ?? 0))]
        // Unmeasured parts stay in the legend as "—" but out of the stack,
        // where they'd only draw flat lines over the band below.
        let series = chip.filter { $0.watts != nil }.map { GraphSeries(values: $0.values, color: $0.color) }
            + [GraphSeries(values: rest, color: Theme.restOfSystem)]
        // The legend's two lines and the note's two come out of the height.
        let height = Hero.height(pane: pane, extra: 2 * Hero.legendLine + 40)
        return DeviceCard(tint: Theme.power, legend: legend, footnote: Self.restNote(components)) {
            DeviceCaption(title: "Where the power goes", trailing: power.systemWatts.map { "\(Format.watts($0)) total" } ?? "")
        } plot: {
            GraphView(series: series, showsGrid: false, glows: true, stacked: true, minimumCeiling: 5, axis: Format.watts,
                      cornerRadius: 8)
                .heroPlot(height: height, tint: Theme.power)
        } figures: {
            figures(power)
        }
    }

    /// What "Rest of system" holds. A part that isn't measured lands in it
    /// too, so the note names it, and says why when the energy counters
    /// aren't live (on an M5 Pro they update in bursts minutes apart).
    private static func restNote(_ components: PowerComponents) -> String {
        let base = "Rest of system covers the display, storage, radios, fans and power conversion."
        let names: [PowerComponent: String] = [.cpu: "the CPU", .gpu: "the GPU", .ane: "the Neural Engine", .dram: "memory"]
        let unmeasured = PowerComponent.allCases.filter { !components.isMeasured($0) }.compactMap { names[$0] }
        guard !unmeasured.isEmpty else { return base }
        let parts = ListFormatter.localizedString(byJoining: unmeasured)
        return components.energyCountersStalled
            ? "\(base) Here it also includes \(parts), as this Mac's energy counters for them aren't updating live."
            : "\(base) Here it also includes \(parts), which this Mac doesn't measure separately."
    }

    // MARK: - Energy since launch

    private func energy() -> some View {
        let history = model.powerDetail
        let measured = [
            Share(name: "CPU", color: Theme.cpu, joules: history.componentEnergy[.cpu]),
            Share(name: "GPU", color: Theme.gpu, joules: history.componentEnergy[.gpu]),
            Share(name: "Neural Engine", color: Theme.neuralEngine, joules: history.componentEnergy[.ane]),
            Share(name: "Memory", color: Theme.dram, joules: history.componentEnergy[.dram]),
        ].compactMap { $0 }
        let rest = max(history.energy - measured.reduce(0) { $0 + $1.joules }, 0)
        let shares = measured + [Share(name: "Rest of system", color: Theme.restOfSystem, joules: rest)]
        let total = max(history.energy, .leastNonzeroMagnitude)
        return ChartCard(
            title: "Energy since launch",
            trailing: "\(Self.wattHours(history.energy)) over \(Format.duration(history.seconds))",
            tint: Theme.power,
            legend: shares.map {
                LegendItem(name: $0.name, color: $0.color, value: "\(Self.wattHours($0.joules)) · \(Format.percent($0.joules / total))")
            },
            timed: false
        ) {
            ShareBar(segments: shares.map { ($0.color, $0.joules) })
                .frame(height: 14)
        }
    }

    private struct Share {
        let name: String
        let color: Color
        let joules: Double

        init(name: String, color: Color, joules: Double) {
            self.name = name
            self.color = color
            self.joules = joules
        }

        /// nil when the part wasn't measured at all.
        init?(name: String, color: Color, joules: Double?) {
            guard let joules else { return nil }
            self.init(name: name, color: color, joules: joules)
        }
    }

    private static func wattHours(_ joules: Double) -> String {
        let value = joules / 3600
        return Format.fixed(value, value < 10 ? 2 : 1) + " Wh"
    }

    // MARK: - Clusters

    private func clusterPower(_ clusters: [ClusterPower]) -> some View {
        let history = model.powerDetail.clusterWatts
        let legend = clusters.enumerated().map { index, cluster in
            LegendItem(name: cluster.name, color: Theme.series(index), value: cluster.watts.map(Format.watts) ?? "—")
        }
        return ChartCard(title: "CPU clusters", trailing: "", tint: Theme.cpu, legend: legend) {
            GraphView(
                series: clusters.enumerated().map { index, cluster in
                    GraphSeries(values: history[cluster.name]?.values ?? [], color: Theme.series(index), fill: false)
                },
                glows: true, minimumCeiling: 2, axis: Format.watts, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.secondary, tint: Theme.cpu)
        }
    }

    // MARK: - Adapter and battery

    private func supply(_ power: PowerSample) -> some View {
        let history = model.powerDetail
        let flow = power.adapter?.batteryWatts ?? power.battery?.watts
        var legend: [LegendItem] = []
        if let adapter = power.adapter {
            let rated = adapter.ratedWatts.map { " of \(Format.fixed($0, 0)) W" } ?? ""
            legend.append(LegendItem(name: "From adapter", color: Theme.power, value: (adapter.inputWatts.map(Format.watts) ?? "—") + rated))
        }
        if power.battery != nil {
            legend.append(LegendItem(name: "Into battery", color: Self.charging, value: Format.watts(max(flow ?? 0, 0))))
            legend.append(LegendItem(name: "From battery", color: Self.discharging, value: Format.watts(max(-(flow ?? 0), 0))))
        }
        return ChartCard(title: "Power supply", trailing: "", tint: Self.charging, legend: legend) {
            GraphView(
                series: [
                    GraphSeries(values: history.adapterInput.values, color: Theme.power, fill: false),
                    GraphSeries(values: history.battery.values.map { max($0, 0) }, color: Self.charging),
                    GraphSeries(values: history.battery.values.map { max(-$0, 0) }, color: Self.discharging),
                ],
                glows: true, minimumCeiling: 5, axis: Format.watts, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.secondary, tint: Self.charging)
            if let battery = power.battery { batteryStats(battery) }
        }
    }

    private func batteryStats(_ battery: BatterySample) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 12) {
            Stat(label: "Battery", number: Double(battery.percent), color: Self.charging) { "\(Int($0.rounded()))%" }
            Stat(label: "State", value: battery.isCharging ? "Charging" : battery.isFullyCharged ? "Full"
                : battery.isPluggedIn ? "Not charging" : "On battery")
            if let minutes = battery.minutesRemaining {
                Stat(label: battery.isCharging ? "Until full" : "Remaining", value: Format.duration(Double(minutes) * 60))
            }
            if let health = battery.health { Stat(label: "Health", value: Format.percent(health)) }
            if let cycles = battery.cycleCount { Stat(label: "Cycles", value: String(cycles)) }
            if let temperature = battery.temperatureCelsius { Stat(label: "Temperature", value: Format.fixed(temperature, 1) + " °C") }
        }
        .padding(.top, 4)
    }

    // MARK: - Stats and apps

    @ViewBuilder
    private func figures(_ power: PowerSample) -> some View {
        if let watts = power.systemWatts {
            Stat(label: "System power", number: watts, color: Theme.power, format: Format.watts)
        }
        if let average = model.powerDetail.averageWatts {
            Stat(label: "Average since launch", number: average, format: Format.watts)
        }
        if model.peakSystemWatts > 0 {
            Stat(label: "Highest seen", number: model.peakSystemWatts, format: Format.watts)
        }
        Stat(label: "Thermal state", value: power.thermalState.rawValue.capitalized)
        Stat(label: "Low Power Mode", value: power.isLowPowerMode ? "On" : "Off")
    }

    /// Apps' estimated draw, stacked. Per-process energy only covers CPU and
    /// GPU work, so this sits below the whole-system figure.
    private func byApp() -> some View {
        let apps = model.topApps(by: .power, count: 5)
        let other = GraphMath.remainder(of: model.processPowerHistory.values, minus: apps.map(\.values))
        let colors = Theme.appColors(for: apps.map(\.id), in: "power")
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: colors[$0]) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: colors[$0], value: Format.watts($1.current), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.watts(other.last ?? 0))]
        // Over the same window as the graphs above, so they line up.
        return ChartCard(title: "Power by app", trailing: "CPU and GPU work", tint: Theme.power, legend: legend) {
            GraphView(series: series, glows: true, stacked: true, minimumCeiling: 1, axis: Format.watts, cornerRadius: 8)
                .chartFrame(height: DetailGraph.secondary, tint: Theme.power)
        }
    }
}
