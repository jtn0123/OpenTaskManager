import Foundation

/// Gathers one tick's sensors, clocks and power figures into the rows of the
/// sensor table. It only reuses what the samplers already read; a figure the
/// Mac doesn't report gets no row, and one that's missing for a moment (an
/// idle cluster's clock) keeps its row with no value.
public enum SensorTable {
    /// The span temperatures' range bars are drawn on.
    public static let temperatureScale = 20.0...110.0

    /// Every row this tick's readings give, in table order.
    public static func readings(sensors: SensorSample?, power: PowerSample?, gpus: [GPUSample], ordered: Bool = true) -> [SensorReading] {
        var rows: [SensorReading] = []
        if let sensors {
            appendTemperatures(sensors, to: &rows)
        }
        appendGPUs(gpus, to: &rows)
        if let power {
            if let components = power.components {
                appendComponents(components, to: &rows)
            }
            appendBattery(power, hasTemperature: rows.contains { $0.group == .battery }, to: &rows)
            appendPower(power, rails: sensors?.rails ?? [], to: &rows)
        }
        if let sensors {
            appendFans(sensors.fans, to: &rows)
        }
        // History and ranges use IDs, so only the visible table needs sorting.
        guard ordered else { return rows }
        // Sorted by group and rank; rows of equal rank keep the order they
        // were added in, which for temperatures is natural label order.
        return rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.group != rhs.element.group { return lhs.element.group < rhs.element.group }
                if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The rows whose label, group, source, origin or unit contains every
    /// word of the query, ignoring case.
    public static func filter(_ rows: [SensorReading], matching query: String) -> [SensorReading] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return rows }
        return rows.filter { row in
            let fields = [row.label, row.group.title, row.source.title, row.origin ?? "", row.unit.symbol]
            return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
        }
    }

    /// Whether the thermal pressure row matches the query, by the same rule.
    public static func pressureMatches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let fields = ["Thermal pressure", "macOS"]
        return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
    }

    // MARK: - Groups

    private static func appendTemperatures(_ sensors: SensorSample, to rows: inout [SensorReading]) {
        if let hottest = sensors.hottest(.chip) {
            rows.append(SensorReading(id: "chip/hottest", group: .chip, rank: 0, label: "Hottest", unit: .celsius,
                                      source: .derived, value: hottest, scale: temperatureScale))
        }
        if sensors.temperatures.filter({ $0.kind == .chip }).count > 1, let average = sensors.average(.chip) {
            rows.append(SensorReading(id: "chip/average", group: .chip, rank: 1, label: "Average", unit: .celsius,
                                      source: .derived, value: average, scale: temperatureScale))
        }
        let batteries = sensors.temperatures.filter { $0.group == .battery }.count
        var battery = 0
        for temperature in sensors.temperatures {
            // The Battery group lists its temperatures first: a lone sensor
            // is just "Temperature", and several are numbered.
            var label = temperature.label
            if temperature.group == .battery {
                battery += 1
                label = batteries == 1 ? "Temperature" : "Temperature \(battery)"
            }
            rows.append(SensorReading(
                id: "temperature/\(temperature.name)", group: temperature.group, rank: temperature.group == .battery ? 0 : 100,
                label: label, unit: .celsius, source: .hidSensor, origin: temperature.name, value: temperature.celsius,
                scale: temperatureScale
            ))
        }
    }

    /// Each GPU's clock and active share, from IOReport's GPU residency. A
    /// GPU without it (a VM's paravirtual one) gets no rows.
    private static func appendGPUs(_ gpus: [GPUSample], to rows: inout [SensorReading]) {
        for (index, gpu) in gpus.enumerated() {
            guard let active = gpu.activeResidency else { continue }
            let prefix = gpus.count > 1 ? "\(gpu.name) " : ""
            let rank = 10 + index * 2
            rows.append(SensorReading(
                id: "gpu/\(gpu.id)/clock", group: .gpu, rank: rank, label: prefix.isEmpty ? "Clock" : "\(prefix)clock",
                unit: .megahertz, source: .ioReport, origin: gpu.name, value: gpu.frequencyMHz,
                note: active > 0 ? "unknown" : "idle"
            ))
            rows.append(SensorReading(id: "gpu/\(gpu.id)/active", group: .gpu, rank: rank + 1,
                                      label: prefix.isEmpty ? "Active" : "\(prefix)active", unit: .fraction,
                                      source: .ioReport, origin: gpu.name, value: active, scale: 0...1))
        }
    }

    private static func appendComponents(_ components: PowerComponents, to rows: inout [SensorReading]) {
        let cpuFromSMC = components.sources[.cpu] == .smc
        if let watts = components.watts(.cpu) {
            rows.append(SensorReading(id: "cpu/power", group: .cpu, rank: 0, label: "Power", unit: .watts,
                                      source: cpuFromSMC ? .smc : .ioReportEnergy,
                                      origin: cpuFromSMC ? PowerSampler.smcCPUKey : "CPU Energy", value: watts))
        }
        for (index, cluster) in components.clusters.enumerated() {
            let rank = 10 + index * 3
            // Without residency the cluster's states weren't read at all.
            if let active = cluster.activeFraction {
                rows.append(SensorReading(
                    id: "cpu/\(cluster.channel)/clock", group: .cpu, rank: rank, label: "\(cluster.name) clock",
                    unit: .megahertz, source: .ioReport, origin: cluster.channel, value: cluster.frequencyMHz,
                    note: active > 0 ? "unknown" : "idle"
                ))
                rows.append(SensorReading(id: "cpu/\(cluster.channel)/active", group: .cpu, rank: rank + 1,
                                          label: "\(cluster.name) active", unit: .fraction, source: .ioReport,
                                          origin: cluster.channel, value: active, scale: 0...1))
            }
            if let watts = cluster.watts {
                rows.append(SensorReading(id: "cpu/\(cluster.channel)/power", group: .cpu, rank: rank + 2,
                                          label: "\(cluster.name) power", unit: .watts, source: .ioReportEnergy,
                                          origin: cluster.channel, value: watts))
            }
        }

        if let watts = components.watts(.gpu) {
            rows.append(SensorReading(id: "gpu/power", group: .gpu, rank: 0, label: "Power", unit: .watts,
                                      source: .ioReportEnergy, origin: "GPU Energy", value: watts))
        }
        if let watts = components.watts(.ane) {
            rows.append(SensorReading(id: "ane/power", group: .neuralEngine, rank: 0, label: "Power", unit: .watts,
                                      source: .ioReportEnergy, origin: "ANE", value: watts))
        }
        if let watts = components.watts(.dram) {
            rows.append(SensorReading(id: "dram/power", group: .memory, rank: 0, label: "DRAM power", unit: .watts,
                                      source: .ioReportEnergy, origin: "DRAM", value: watts))
        }
    }

    private static func appendBattery(_ power: PowerSample, hasTemperature: Bool, to rows: inout [SensorReading]) {
        guard let battery = power.battery else { return }
        if !hasTemperature, let celsius = battery.temperatureCelsius {
            rows.append(SensorReading(id: "battery/temperature", group: .battery, rank: 0, label: "Temperature",
                                      unit: .celsius, source: .batteryGauge, origin: "Temperature", value: celsius,
                                      scale: temperatureScale))
        }
        if let voltage = battery.voltage {
            rows.append(SensorReading(id: "battery/voltage", group: .battery, rank: 1, label: "Voltage", unit: .volts,
                                      source: .batteryGauge, origin: "Voltage", value: voltage))
        }
        if let amperage = battery.amperage {
            rows.append(SensorReading(id: "battery/current", group: .battery, rank: 2, label: "Current", unit: .amperes,
                                      source: .batteryGauge, origin: "Amperage", value: amperage))
        }
        if let watts = battery.watts {
            rows.append(SensorReading(id: "battery/power", group: .battery, rank: 3, label: "Power", unit: .watts,
                                      source: .batteryGauge, origin: "Voltage × Amperage", value: watts))
        }
    }

    private static func appendPower(_ power: PowerSample, rails: [SensorSample.Rail], to rows: inout [SensorReading]) {
        if let watts = power.systemWatts {
            let (source, origin) = systemOrigin(power.systemWattsSource)
            rows.append(SensorReading(id: "power/system", group: .power, rank: 0, label: "System total", unit: .watts,
                                      source: source, origin: origin, value: watts))
        }
        // A laptop running on its battery has nothing on its DC input.
        let unplugged = power.adapter == nil && power.battery != nil
        let smc = power.systemWattsSource == .smcSystemTotal || power.systemWattsSource == .smcInput
        if power.adapter != nil || !rails.isEmpty {
            rows.append(SensorReading(id: "power/input", group: .power, rank: 1, label: "DC input", unit: .watts,
                                      source: smc ? .smc : .batteryGauge, origin: smc ? "PDTR" : "PowerTelemetryData",
                                      value: unplugged ? nil : power.adapter?.inputWatts,
                                      note: unplugged ? "unplugged" : "no reading"))
        }
        for (index, rail) in rails.enumerated() {
            rows.append(SensorReading(id: "rail/\(rail.id)", group: .power, rank: 2 + index, label: rail.label,
                                      unit: rail.unit, source: .smc, origin: rail.id,
                                      value: unplugged ? nil : rail.value, note: "unplugged"))
        }
    }

    private static func systemOrigin(_ source: SystemPowerSource?) -> (SensorSource, String?) {
        switch source {
        case .smcSystemTotal: (.smc, "PSTR")
        case .smcInput: (.smc, "PDTR")
        case .batteryTelemetry: (.batteryGauge, "PowerTelemetryData")
        case .batteryDischarge: (.batteryGauge, "Voltage × Amperage")
        case nil: (.smc, nil)
        }
    }

    private static func appendFans(_ fans: [SensorSample.Fan], to rows: inout [SensorReading]) {
        for fan in fans {
            rows.append(SensorReading(
                id: "fan/\(fan.id)", group: .fans, rank: fan.id, label: fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan",
                unit: .rpm, source: .smc, origin: "F\(fan.id)Ac", value: fan.rpm,
                scale: fan.maximumRPM.flatMap { $0 > 0 ? 0...$0 : nil }
            ))
        }
    }
}
