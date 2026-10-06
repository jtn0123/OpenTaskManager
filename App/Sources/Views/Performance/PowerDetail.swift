import OTMKit
import SwiftUI

struct PowerDetail: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    var body: some View {
        let power = snapshot.power
        let history = model.powerHistory.values
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Power", subtitle: power.battery == nil ? "AC power" : "Battery")
            if power.systemWatts != nil {
                GraphPanel(title: "Whole-system power draw", trailing: "",
                           series: [GraphSeries(values: history, color: Theme.power)], height: 200,
                           minimumCeiling: 5, axis: Format.watts)
            }
            HStack(spacing: 24) {
                if let watts = power.systemWatts { Stat(label: "System power", value: Format.watts(watts), color: Theme.power) }
                Stat(label: "Thermal state", value: power.thermalState.rawValue.capitalized)
                Stat(label: "Low Power Mode", value: power.isLowPowerMode ? "On" : "Off")
            }
            if let battery = power.battery {
                HStack(spacing: 24) {
                    Stat(label: "Battery", value: "\(battery.percent)%")
                    Stat(label: "State", value: battery.isCharging ? "Charging" : battery.isPluggedIn ? "Plugged in" : "On battery")
                    if let minutes = battery.minutesRemaining {
                        Stat(label: battery.isCharging ? "Until full" : "Remaining", value: Format.duration(Double(minutes) * 60))
                    }
                }
                HStack(spacing: 24) {
                    if let health = battery.health { Stat(label: "Health", value: Format.percent(health)) }
                    if let cycles = battery.cycleCount { Stat(label: "Cycles", value: String(cycles)) }
                    if let temperature = battery.temperatureCelsius { Stat(label: "Temperature", value: Format.fixed(temperature, 1) + " °C") }
                }
            }
            byApp()
            TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: model.appGroups,
                        metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, minimum: 0.01)
        }
    }

    /// Apps' estimated draw, stacked. Per-process energy only covers CPU and
    /// GPU work, so this sits below the whole-system figure.
    private func byApp() -> some View {
        let apps = model.topApps(by: \.powerWatts, count: 5)
        let other = AppModel.remainder(of: model.processPowerHistory.values, minus: apps.map(\.values))
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: Theme.series($0)) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: Theme.series($0), value: Format.watts($1.current), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.watts(other.last ?? 0))]
        return ChartCard(title: "Power by app", trailing: "CPU and GPU work, last 2 minutes", tint: Theme.power, legend: legend) {
            GraphView(series: series, capacity: AppModel.processHistoryCapacity - 2, glows: true, stacked: true,
                      minimumCeiling: 1, axis: Format.watts, cornerRadius: 8)
                .chartFrame(height: 180, tint: Theme.power)
        }
    }
}
