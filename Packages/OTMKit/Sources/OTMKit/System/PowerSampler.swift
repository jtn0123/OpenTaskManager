import Foundation
import IOKit

enum PowerReader {
    static func read() -> PowerSample {
        var battery: BatterySample?
        var systemWatts: Double?

        IORegistry.forEachService(matching: "AppleSmartBattery") { service in
            let properties = IORegistry.properties(of: service)

            // Apple silicon laptops report whole-system power in milliwatts.
            if let telemetry = properties.dictionary("PowerTelemetryData") {
                if let load = telemetry.double("SystemLoad"), load > 0 {
                    systemWatts = load / 1000
                } else if let input = telemetry.double("SystemPowerIn"), input > 0 {
                    systemWatts = input / 1000
                }
            }

            guard properties.bool("BatteryInstalled") != false else { return }
            let design = properties.double("DesignCapacity")
            let rawMax = properties.double("AppleRawMaxCapacity") ?? properties.double("NominalChargeCapacity")
            let remaining = properties.int("TimeRemaining") ?? properties.int("AvgTimeToEmpty")
            let amperage = properties.int("Amperage").map { Double($0) / 1000 }
            let voltage = properties.double("Voltage").map { $0 / 1000 }
            var health: Double?
            if let rawMax, let design, design > 0 {
                health = min(rawMax / design, 1.2)
            }
            battery = BatterySample(
                percent: properties.int("CurrentCapacity") ?? 0,
                isCharging: properties.bool("IsCharging") ?? false,
                isPluggedIn: properties.bool("ExternalConnected") ?? false,
                isFullyCharged: properties.bool("FullyCharged") ?? false,
                cycleCount: properties.int("CycleCount"),
                health: health,
                temperatureCelsius: properties.double("Temperature").map { $0 / 100 },
                minutesRemaining: remaining.flatMap { $0 > 0 && $0 < 0xFFFF ? $0 : nil },
                voltage: voltage,
                amperage: amperage
            )
            // Without telemetry, battery draw approximates system power on battery.
            if systemWatts == nil, let voltage, let amperage, amperage < 0 {
                systemWatts = voltage * -amperage
            }
        }

        let info = ProcessInfo.processInfo
        return PowerSample(
            systemWatts: systemWatts,
            battery: battery,
            isLowPowerMode: info.isLowPowerModeEnabled,
            thermalState: ThermalState(info.thermalState)
        )
    }
}
