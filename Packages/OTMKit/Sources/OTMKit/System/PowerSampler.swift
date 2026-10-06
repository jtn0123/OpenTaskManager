import Foundation
import IOKit

/// What the AppleSmartBattery service reports, reduced to plain values.
struct BatteryReading {
    var battery: BatterySample?
    /// An adapter is plugged in.
    var isExternalConnected = false
    var adapterName: String?
    var adapterRatedWatts: Double?
    /// `PowerTelemetryData` values, converted from milliwatts to watts.
    var telemetrySystemLoad: Double?
    var telemetryPowerIn: Double?

    /// Parses the service's properties (`ioreg -r -c AppleSmartBattery`).
    static func parse(_ properties: [String: Any]) -> BatteryReading {
        var reading = BatteryReading()
        reading.isExternalConnected = properties.bool("ExternalConnected") ?? false

        // Apple silicon laptops report whole-system power in milliwatts.
        if let telemetry = properties.dictionary("PowerTelemetryData") {
            reading.telemetrySystemLoad = telemetry.double("SystemLoad").map { $0 / 1000 }
            reading.telemetryPowerIn = telemetry.double("SystemPowerIn").map { $0 / 1000 }
            if reading.telemetryPowerIn ?? 0 <= 0, let volts = telemetry.double("SystemVoltageIn"),
               let amps = telemetry.double("SystemCurrentIn") {
                reading.telemetryPowerIn = volts * amps / 1_000_000
            }
        }

        if let adapter = properties.dictionary("AdapterDetails") {
            reading.adapterName = adapter.string("Name").flatMap { $0.isEmpty ? nil : $0 }
            reading.adapterRatedWatts = adapter.double("Watts").flatMap { $0 > 0 ? $0 : nil }
        }

        guard properties.bool("BatteryInstalled") != false else { return reading }
        let design = properties.double("DesignCapacity")
        let rawMax = properties.double("AppleRawMaxCapacity") ?? properties.double("NominalChargeCapacity")
        let remaining = properties.int("TimeRemaining") ?? properties.int("AvgTimeToEmpty")
        var health: Double?
        if let rawMax, let design, design > 0 {
            health = min(rawMax / design, 1.2)
        }
        reading.battery = BatterySample(
            percent: properties.int("CurrentCapacity") ?? 0,
            isCharging: properties.bool("IsCharging") ?? false,
            isPluggedIn: reading.isExternalConnected,
            isFullyCharged: properties.bool("FullyCharged") ?? false,
            cycleCount: properties.int("CycleCount"),
            health: health,
            temperatureCelsius: properties.double("Temperature").map { $0 / 100 },
            minutesRemaining: remaining.flatMap { $0 > 0 && $0 < 0xFFFF ? $0 : nil },
            voltage: properties.double("Voltage").map { $0 / 1000 },
            amperage: properties.int("Amperage").map { Double($0) / 1000 }
        )
        return reading
    }
}

/// Picks the best whole-system power figure and describes the adapter.
enum PowerSourceSelection {
    /// Readings above this are treated as garbage; the largest Mac power supply is 1.4 kW.
    static let maximumPlausibleWatts = 5000.0

    static func plausible(_ watts: Double?) -> Double? {
        guard let watts, watts.isFinite, watts > 0, watts < maximumPlausibleWatts else { return nil }
        return watts
    }

    /// Laptops report whole-system power twice: the SMC's PSTR key and the
    /// battery gauge's `PowerTelemetryData.SystemLoad`. On an M5 Pro on AC they
    /// agreed (73.5 W against 73.1 W), but PSTR changed every second while the
    /// gauge's telemetry kept the same `UpdateTime` for over a minute, so the
    /// SMC wins whenever it can be read. Desktops have no battery gauge, so the
    /// SMC is their only source. PDTR (DC input) is the same figure while the
    /// battery isn't charging, but includes charging power, so it ranks below
    /// the gauge. Battery discharge (volts times amps) is the last resort.
    static func systemPower(
        smcSystemTotal: Double?, smcInput: Double?, reading: BatteryReading?
    ) -> (watts: Double, source: SystemPowerSource)? {
        if let watts = plausible(smcSystemTotal) { return (watts, .smcSystemTotal) }
        if let watts = plausible(reading?.telemetrySystemLoad) { return (watts, .batteryTelemetry) }
        if let watts = plausible(smcInput) { return (watts, .smcInput) }
        if let watts = plausible(reading?.telemetryPowerIn) { return (watts, .batteryTelemetry) }
        if let flow = reading?.battery?.watts, let watts = plausible(-flow) { return (watts, .batteryDischarge) }
        return nil
    }

    /// nil unless an adapter is plugged in. Live input comes from the SMC's
    /// DC-input key when it can be read, else from the battery gauge.
    static func adapter(reading: BatteryReading?, smcInput: Double?) -> AdapterSample? {
        guard let reading, reading.isExternalConnected else { return nil }
        return AdapterSample(
            name: reading.adapterName,
            ratedWatts: reading.adapterRatedWatts,
            inputWatts: plausible(smcInput) ?? plausible(reading.telemetryPowerIn),
            batteryWatts: reading.battery?.watts
        )
    }
}

/// Reads whole-system power, the battery and the adapter. Owns one SMC
/// connection for its lifetime.
final class PowerSampler {
    private let smc = SMCConnection()

    func sample() -> PowerSample {
        var reading: BatteryReading?
        IORegistry.forEachService(matching: "AppleSmartBattery") { service in
            reading = BatteryReading.parse(IORegistry.properties(of: service))
        }
        let smcSystemTotal = smc?.double("PSTR")
        let smcInput = smc?.double("PDTR")
        let system = PowerSourceSelection.systemPower(smcSystemTotal: smcSystemTotal, smcInput: smcInput, reading: reading)

        let info = ProcessInfo.processInfo
        return PowerSample(
            systemWatts: system?.watts,
            battery: reading?.battery,
            isLowPowerMode: info.isLowPowerModeEnabled,
            thermalState: ThermalState(info.thermalState),
            adapter: PowerSourceSelection.adapter(reading: reading, smcInput: smcInput),
            systemWattsSource: system?.source
        )
    }
}
