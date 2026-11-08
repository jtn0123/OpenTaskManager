import Foundation
import OTMKit

struct PowerReport: Encodable {
    let interval: TimeInterval
    let power: PowerSample
    let gpus: [GPUSample]
}

func describe(_ source: SystemPowerSource) -> String {
    switch source {
    case .smcSystemTotal: "SMC system total"
    case .batteryTelemetry: "battery gauge"
    case .smcInput: "SMC DC input"
    case .batteryDischarge: "battery discharge"
    }
}

/// Signed battery flow: "+12.0 W charging", "-8.21 W discharging".
func batteryFlow(_ watts: Double) -> String {
    if abs(watts) < 0.05 { return "idle" }
    return (watts > 0 ? "+" : "-") + Format.watts(abs(watts)) + (watts > 0 ? " charging" : " discharging")
}

func powerSummary(_ snapshot: SystemSnapshot) -> String {
    let power = snapshot.power
    var lines: [String] = []
    if let watts = power.systemWatts {
        lines.append("System    \(Format.watts(watts))" + (power.systemWattsSource.map { " (\(describe($0)))" } ?? ""))
    } else {
        lines.append("System    unavailable")
    }
    if let adapter = power.adapter {
        var line = "Adapter   \(adapter.name ?? "connected")"
        if let rated = adapter.ratedWatts { line += ", rated " + (rated == rated.rounded() ? "\(Int(rated)) W" : Format.watts(rated)) }
        if let input = adapter.inputWatts { line += ", drawing \(Format.watts(input))" }
        lines.append(line)
    }
    if let battery = power.battery {
        let flow = battery.watts.map { ", \(batteryFlow($0))" } ?? ""
        lines.append("Battery   \(battery.percent)%\(flow)")
    }

    if let components = power.components {
        lines.append("Components (measured total \(Format.watts(components.total)))")
        let names: [(PowerComponent, String)] = [(.cpu, "CPU"), (.gpu, "GPU"), (.ane, "ANE"), (.dram, "DRAM")]
        // The ANE and DRAM have no figure but the power manager's counters.
        let why = components.energyCountersStalled ? ": this Mac's energy counters aren't updating live" : ""
        for (component, name) in names {
            guard let watts = components.watts(component) else {
                lines.append("  \(pad(name, 6))—  not measured\(why)")
                continue
            }
            let note = components.sources[component] == .smc ? "  (SMC)" : ""
            lines.append("  \(pad(name, 6))\(Format.watts(watts))\(note)")
        }
        if !components.clusters.isEmpty {
            lines.append("  " + pad("CLUSTER", 24) + pad("POWER", 9, right: true) + pad("CLOCK", 11, right: true) + pad("ACTIVE", 8, right: true))
            for cluster in components.clusters {
                lines.append("  " + pad("\(cluster.name) (\(cluster.channel))", 24)
                    + pad(cluster.watts.map(Format.watts) ?? "—", 9, right: true)
                    + pad(cluster.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "—", 11, right: true)
                    + pad(cluster.activeFraction.map { Format.percent($0, digits: 1) } ?? "—", 8, right: true))
            }
        }
    } else {
        lines.append("Components unavailable (no IOReport energy data)")
    }
    for gpu in snapshot.gpus {
        let clock = gpu.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "—"
        let active = gpu.activeResidency.map { Format.percent($0, digits: 1) } ?? "—"
        lines.append("GPU       \(gpu.name): clock \(clock), active \(active)")
    }
    lines.append("Thermal   \(power.thermalState.rawValue)" + (power.isLowPowerMode ? ", Low Power Mode on" : ""))
    return lines.joined(separator: "\n")
}

@MainActor
func powerCommand(_ options: Options) async throws {
    // The process list isn't shown, so don't pay for it.
    var sampling = SystemMonitor.Options()
    sampling.includeProcesses = false
    await monitor.setOptions(sampling)
    let snapshot = try await monitor.measuredSample(over: .seconds(options.interval))
    if options.json {
        printJSON(PowerReport(interval: snapshot.interval, power: snapshot.power, gpus: snapshot.gpus))
    } else {
        print(powerSummary(snapshot))
    }
}
