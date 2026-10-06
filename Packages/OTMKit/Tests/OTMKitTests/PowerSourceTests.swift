@testable import OTMKit
import Testing

/// Fixtures modelled on `ioreg -r -c AppleSmartBattery` from an M5 Pro
/// MacBook Pro on its 140 W adapter (serial numbers left out).
struct PowerSourceTests {
    static var onAdapter: [String: Any] { [
        "BatteryInstalled": true,
        "ExternalConnected": true,
        "IsCharging": false,
        "FullyCharged": false,
        "CurrentCapacity": 80,
        "CycleCount": 3,
        "DesignCapacity": 8579,
        "AppleRawMaxCapacity": 8802,
        "Voltage": 12349,
        "Amperage": 0,
        "Temperature": 3050,
        "AdapterDetails": [
            "Name": "140W USB-C Power Adapter",
            "Watts": 140,
            "AdapterVoltage": 28000,
            "Current": 4990,
            "Description": "pd charger",
        ] as [String: Any],
        "PowerTelemetryData": [
            "SystemLoad": 73139,
            "SystemPowerIn": 73139,
            "SystemVoltageIn": 27380,
            "SystemCurrentIn": 2672,
            "BatteryPower": 0,
        ] as [String: Any],
    ] }

    static func onBattery(amperage: Int) -> [String: Any] {
        var properties = onAdapter
        properties["ExternalConnected"] = false
        properties["Amperage"] = amperage
        properties["PowerTelemetryData"] = ["SystemLoad": 0, "SystemPowerIn": 0] as [String: Any]
        return properties
    }

    @Test func parsesAdapterBatteryAndTelemetry() throws {
        let reading = BatteryReading.parse(Self.onAdapter)
        #expect(reading.isExternalConnected)
        #expect(reading.adapterName == "140W USB-C Power Adapter")
        #expect(reading.adapterRatedWatts == 140)
        #expect(reading.telemetrySystemLoad == 73.139)
        #expect(reading.telemetryPowerIn == 73.139)
        let battery = try #require(reading.battery)
        #expect(battery.percent == 80)
        #expect(battery.isPluggedIn)
        #expect(battery.voltage == 12.349)
        #expect(battery.watts == 0)
        #expect(battery.temperatureCelsius == 30.5)
    }

    @Test func readsCapacitiesFromBatteryData() throws {
        // macOS 27 only reports the capacities inside BatteryData.
        var properties = Self.onAdapter
        properties["DesignCapacity"] = nil
        properties["AppleRawMaxCapacity"] = nil
        properties["BatteryData"] = ["DesignCapacity": 8579, "AppleRawMaxCapacity": 8802, "NominalChargeCapacity": 9046] as [String: Any]
        let health = try #require(BatteryReading.parse(properties).battery?.health)
        #expect(abs(health - 8802.0 / 8579.0) < 1e-9)

        properties["BatteryData"] = ["DesignCapacity": 8579] as [String: Any]
        #expect(BatteryReading.parse(properties).battery?.health == nil)
    }

    @Test func batteryWattsAreSignedByCurrentDirection() throws {
        var charging = Self.onAdapter
        charging["Amperage"] = 2000
        #expect(try #require(BatteryReading.parse(charging).battery?.watts) > 24)
        let discharging = try #require(BatteryReading.parse(Self.onBattery(amperage: -1500)).battery?.watts)
        #expect(abs(discharging - -18.5235) < 0.0001)
    }

    @Test func telemetryInputFallsBackToVoltsTimesAmps() {
        var properties = Self.onAdapter
        properties["PowerTelemetryData"] = ["SystemPowerIn": 0, "SystemVoltageIn": 20000, "SystemCurrentIn": 1500] as [String: Any]
        #expect(BatteryReading.parse(properties).telemetryPowerIn == 30)
    }

    @Test func prefersTheSMCTotalThenTheGaugeThenDCInput() throws {
        let reading = BatteryReading.parse(Self.onAdapter)
        let smc = try #require(PowerSourceSelection.systemPower(smcSystemTotal: 74.7, smcInput: 75.9, reading: reading))
        #expect(smc.watts == 74.7)
        #expect(smc.source == .smcSystemTotal)

        let gauge = try #require(PowerSourceSelection.systemPower(smcSystemTotal: nil, smcInput: 75.9, reading: reading))
        #expect(gauge.source == .batteryTelemetry)
        #expect(gauge.watts == 73.139)

        // A desktop: no battery service, only the SMC's DC input.
        let desktop = try #require(PowerSourceSelection.systemPower(smcSystemTotal: 0, smcInput: 31, reading: nil))
        #expect(desktop.source == .smcInput)
        #expect(desktop.watts == 31)
    }

    @Test func fallsBackToBatteryDischarge() throws {
        let reading = BatteryReading.parse(Self.onBattery(amperage: -1500))
        let result = try #require(PowerSourceSelection.systemPower(smcSystemTotal: nil, smcInput: nil, reading: reading))
        #expect(result.source == .batteryDischarge)
        #expect(abs(result.watts - 18.5235) < 0.0001)
        // Charging current is not system draw.
        var charging = Self.onAdapter
        charging["Amperage"] = 2000
        charging["PowerTelemetryData"] = [:] as [String: Any]
        #expect(PowerSourceSelection.systemPower(smcSystemTotal: nil, smcInput: nil, reading: BatteryReading.parse(charging)) == nil)
    }

    @Test func rejectsImplausibleReadings() {
        #expect(PowerSourceSelection.plausible(.nan) == nil)
        #expect(PowerSourceSelection.plausible(-3) == nil)
        #expect(PowerSourceSelection.plausible(0) == nil)
        #expect(PowerSourceSelection.plausible(1e9) == nil)
        #expect(PowerSourceSelection.plausible(42) == 42)
    }

    @Test func describesTheAdapterOnlyWhenPluggedIn() throws {
        let adapter = try #require(PowerSourceSelection.adapter(reading: BatteryReading.parse(Self.onAdapter), smcInput: 75.9))
        #expect(adapter.name == "140W USB-C Power Adapter")
        #expect(adapter.ratedWatts == 140)
        #expect(adapter.inputWatts == 75.9)
        #expect(adapter.batteryWatts == 0)

        let gaugeOnly = try #require(PowerSourceSelection.adapter(reading: BatteryReading.parse(Self.onAdapter), smcInput: nil))
        #expect(gaugeOnly.inputWatts == 73.139)

        #expect(PowerSourceSelection.adapter(reading: BatteryReading.parse(Self.onBattery(amperage: -800)), smcInput: 0) == nil)
        #expect(PowerSourceSelection.adapter(reading: nil, smcInput: 40) == nil)
    }
}
