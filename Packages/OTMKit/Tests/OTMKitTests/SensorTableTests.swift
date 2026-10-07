import Foundation
@testable import OTMKit
import Testing

struct SensorTableTests {
    // MARK: - Fixtures

    private static func temperature(_ name: String, _ celsius: Double) -> SensorSample.Temperature {
        SensorModel.temperatures(from: [(name, celsius)])[0]
    }

    private static func battery(voltage: Double? = 12.6, amperage: Double? = -0.5, celsius: Double? = 31) -> BatterySample {
        BatterySample(percent: 80, isCharging: false, isPluggedIn: false, isFullyCharged: false, cycleCount: 3, health: 1,
                      temperatureCelsius: celsius, minutesRemaining: nil, voltage: voltage, amperage: amperage)
    }

    private static func power(battery: BatterySample? = nil, adapter: AdapterSample? = nil, systemWatts: Double? = 8,
                              source: SystemPowerSource? = .smcSystemTotal, components: PowerComponents? = nil,
                              thermal: ThermalState = .nominal) -> PowerSample {
        PowerSample(systemWatts: systemWatts, battery: battery, isLowPowerMode: false, thermalState: thermal,
                    adapter: adapter, systemWattsSource: source, components: components)
    }

    private static let adapter = AdapterSample(name: "140W USB-C Power Adapter", ratedWatts: 140, inputWatts: 2.84, batteryWatts: 0)

    private static func components(clusters: [ClusterPower]) -> PowerComponents {
        PowerComponents(cpu: 1.5, gpu: 0.25, ane: 0, dram: nil, clusters: clusters, sources: [.cpu: .smc, .gpu: .energyModel])
    }

    private static func cluster(_ name: String, channel: String, mhz: Double?, active: Double?) -> ClusterPower {
        ClusterPower(name: name, tierLevel: 0, watts: nil, frequencyMHz: mhz, activeFraction: active, channel: channel)
    }

    private static func gpu(mhz: Double?, active: Double?) -> GPUSample {
        GPUSample(registryID: 7, name: "Apple M5 Pro", coreCount: 20, deviceUtilization: 0.1, rendererUtilization: nil,
                  tilerUtilization: nil, memoryInUse: nil, memoryAllocated: nil, frequencyMHz: mhz, activeResidency: active)
    }

    private static func reading(_ id: String, _ value: Double?, group: SensorGroup = .chip, rank: Int = 100,
                                unit: SensorUnit = .celsius) -> SensorReading {
        SensorReading(id: id, group: group, rank: rank, label: id, unit: unit, source: .hidSensor, value: value, note: "idle")
    }

    // MARK: - Builder

    @Test func groupsTemperaturesByPartWithDerivedRowsFirst() {
        let sensors = SensorSample(temperatures: SensorModel.temperatures(from: [
            ("PMU tdie10", 61), ("PMU tdie2", 55), ("pACC MTR Temp Sensor3", 64), ("GPU MTR Temp Sensor1", 48),
            ("NAND CH0 temp", 38), ("gas gauge battery", 30),
        ]), fans: [])
        let rows = SensorTable.readings(sensors: sensors, power: nil, gpus: [])
        #expect(rows.map(\.group) == [.chip, .chip, .chip, .chip, .cpu, .gpu, .storage, .battery])
        #expect(rows.map(\.label) == ["Hottest", "Average", "Die 2", "Die 10", "Performance cores 3", "GPU 1", "SSD channel 0",
                                      "Temperature"])
        // Block sensors are on the die too, so they count toward the chip's figures.
        #expect(rows[0].id == "chip/hottest" && rows[0].value == 64 && rows[0].source == .derived)
        #expect(rows[1].id == "chip/average" && rows[1].value == 57)
        #expect(rows[2].id == "temperature/PMU tdie2" && rows[2].origin == "PMU tdie2")
        #expect(rows.allSatisfy { $0.unit == .celsius && $0.scale == SensorTable.temperatureScale })
    }

    @Test func namesEachOfSeveralBatterySensors() {
        let sensors = SensorSample(temperatures: [Self.temperature("gas gauge battery", 30), Self.temperature("battery 2", 31)], fans: [])
        let rows = SensorTable.readings(sensors: sensors, power: nil, gpus: [])
        #expect(rows.map(\.label) == ["Temperature 1", "Temperature 2"])
        #expect(rows.map(\.origin) == ["gas gauge battery", "battery 2"])
    }

    @Test func leavesOutTheAverageOfASingleSensor() {
        let sensors = SensorSample(temperatures: [Self.temperature("PMU tdie1", 50)], fans: [])
        let ids = SensorTable.readings(sensors: sensors, power: nil, gpus: []).map(\.id)
        #expect(ids == ["chip/hottest", "temperature/PMU tdie1"])
    }

    @Test func keepsAnIdleClusterWithNoClockRatherThanZero() {
        let power = Self.power(components: Self.components(clusters: [
            Self.cluster("Performance 0", channel: "PCPU", mhz: 3_200, active: 0.4),
            Self.cluster("Efficiency 0", channel: "ECPU", mhz: nil, active: 0),
            Self.cluster("Performance 1", channel: "PCPU1", mhz: nil, active: nil),
        ]))
        let rows = SensorTable.readings(sensors: nil, power: power, gpus: [])
        let busy = rows.first { $0.id == "cpu/PCPU/clock" }
        #expect(busy?.value == 3_200 && busy?.unit == .megahertz && busy?.source == .ioReport)
        let idle = rows.first { $0.id == "cpu/ECPU/clock" }
        #expect(idle != nil && idle?.value == nil && idle?.note == "idle")
        #expect(rows.first { $0.id == "cpu/ECPU/active" }?.value == 0)
        #expect(!rows.contains { $0.id.hasPrefix("cpu/PCPU1/") }, "a cluster with no residency wasn't read at all")
        #expect(rows.first { $0.id == "cpu/power" }?.origin == PowerSampler.smcCPUKey)
        #expect(rows.first { $0.id == "gpu/power" }?.value == 0.25)
        #expect(!rows.contains { $0.id == "ane/power" || $0.id == "dram/power" }, "unmeasured parts get no row")
    }

    @Test func givesTheGPUClockAndActiveShare() {
        let rows = SensorTable.readings(sensors: nil, power: Self.power(), gpus: [Self.gpu(mhz: 1_398, active: 0.2)])
        let gpu = rows.filter { $0.group == .gpu }
        #expect(gpu.map(\.label) == ["Clock", "Active"])
        #expect(gpu[0].value == 1_398 && gpu[1].value == 0.2 && gpu[1].scale == 0...1)
        let off = SensorTable.readings(sensors: nil, power: Self.power(), gpus: [Self.gpu(mhz: nil, active: nil)])
        #expect(!off.contains { $0.group == .gpu })
    }

    @Test func readsTheBatteryGaugeWithItsSign() {
        let rows = SensorTable.readings(sensors: nil, power: Self.power(battery: Self.battery()), gpus: [])
        let battery = rows.filter { $0.group == .battery }
        #expect(battery.map(\.label) == ["Temperature", "Voltage", "Current", "Power"])
        #expect(battery[0].source == .batteryGauge, "the gauge's temperature stands in when there's no HID battery sensor")
        #expect(battery[2].value == -0.5)
        #expect(battery[3].value == 12.6 * -0.5)
        let withSensor = SensorTable.readings(sensors: SensorSample(temperatures: [Self.temperature("gas gauge battery", 30)], fans: []),
                                              power: Self.power(battery: Self.battery()), gpus: [])
        #expect(withSensor.filter { $0.group == .battery && $0.unit == .celsius }.map(\.source) == [.hidSensor])
    }

    @Test func marksTheInputUnpluggedOnBattery() {
        let rails = [SensorSample.Rail(id: "VD0R", label: "DC input voltage", unit: .volts, value: 0)]
        let sensors = SensorSample(temperatures: [], fans: [], rails: rails)
        let onBattery = SensorTable.readings(sensors: sensors, power: Self.power(battery: Self.battery()), gpus: [])
        let input = onBattery.first { $0.id == "power/input" }
        #expect(input?.value == nil && input?.note == "unplugged")
        #expect(onBattery.first { $0.id == "rail/VD0R" }?.note == "unplugged")

        let plugged = SensorTable.readings(sensors: SensorSample(temperatures: [], fans: [], rails: [
            SensorSample.Rail(id: "VD0R", label: "DC input voltage", unit: .volts, value: 27.87),
        ]), power: Self.power(battery: Self.battery(), adapter: Self.adapter, source: .smcInput), gpus: [])
        #expect(plugged.first { $0.id == "power/input" }?.value == 2.84)
        #expect(plugged.first { $0.id == "power/input" }?.origin == "PDTR")
        #expect(plugged.first { $0.id == "power/system" }?.origin == "PDTR")
        #expect(plugged.first { $0.id == "rail/VD0R" }?.value == 27.87)
    }

    @Test func listsNoInputOnADesktopWithoutRails() {
        let rows = SensorTable.readings(sensors: nil, power: Self.power(), gpus: [])
        #expect(rows.map(\.id) == ["power/system"])
        #expect(rows[0].origin == "PSTR" && rows[0].source == .smc)
    }

    @Test func scalesFansToTheirMaximum() {
        let sensors = SensorSample(temperatures: [], fans: [
            SensorSample.Fan(id: 1, rpm: 0, minimumRPM: 1_000, maximumRPM: 5_000),
            SensorSample.Fan(id: 0, rpm: 2_000, minimumRPM: 1_000, maximumRPM: nil),
        ])
        let fans = SensorTable.readings(sensors: sensors, power: nil, gpus: [])
        #expect(fans.map(\.label) == ["Fan 1", "Fan 2"])
        #expect(fans[0].scale == nil && fans[1].scale == 0...5_000)
        #expect(fans[1].value == 0, "a stopped fan reads 0 rpm, a real reading")
        let lone = SensorTable.readings(sensors: SensorSample(temperatures: [], fans: [sensors.fans[0]]), power: nil, gpus: [])
        #expect(lone.map(\.label) == ["Fan"])
    }

    @Test func givesAVirtualMachineNoRows() {
        let rows = SensorTable.readings(sensors: nil, power: Self.power(systemWatts: nil, source: nil), gpus: [
            GPUSample(registryID: 1, name: "Apple Paravirtual device", coreCount: nil, deviceUtilization: nil,
                      rendererUtilization: nil, tilerUtilization: nil, memoryInUse: nil, memoryAllocated: nil),
        ])
        #expect(rows.isEmpty)
    }

    // MARK: - Filter

    @Test func filtersOnEveryWordAcrossFields() {
        let rows = SensorTable.readings(sensors: SensorSample(temperatures: [
            Self.temperature("PMU tdie1", 50), Self.temperature("NAND CH0 temp", 38),
        ], fans: [SensorSample.Fan(id: 0, rpm: 1_200, minimumRPM: nil, maximumRPM: nil)]), power: nil, gpus: [])
        #expect(SensorTable.filter(rows, matching: "").count == rows.count)
        #expect(SensorTable.filter(rows, matching: "ssd").map(\.label) == ["SSD channel 0"])
        #expect(SensorTable.filter(rows, matching: "nand").map(\.label) == ["SSD channel 0"], "matches the sensor's own name")
        #expect(SensorTable.filter(rows, matching: "rpm").map(\.label) == ["Fan"], "matches the unit")
        #expect(SensorTable.filter(rows, matching: "chip die").map(\.label) == ["Die 1"])
        #expect(SensorTable.filter(rows, matching: "chip nand").isEmpty)
        #expect(SensorTable.pressureMatches("thermal"))
        #expect(SensorTable.pressureMatches(""))
        #expect(!SensorTable.pressureMatches("fan"))
    }

    // MARK: - Extremes

    @Test func countsOnlyRealReadings() {
        var extremes = SensorExtremes(since: Date(timeIntervalSince1970: 0))
        extremes.record([Self.reading("a", 40)], thermalState: .nominal)
        extremes.record([Self.reading("a", nil)], thermalState: .nominal)
        extremes.record([Self.reading("a", .nan)], thermalState: nil)
        extremes.record([Self.reading("a", 55)], thermalState: .fair)
        extremes.record([Self.reading("a", 47)], thermalState: .nominal)
        let range = extremes["a"]
        #expect(range?.lowest == 40 && range?.highest == 55 && range?.samples == 3)
        #expect(extremes.samples == 5)
        #expect(extremes.mildestThermalState == .nominal && extremes.worstThermalState == .fair)
    }

    @Test func hasNoRangeForAChannelThatNeverReported() {
        var extremes = SensorExtremes(since: Date())
        extremes.record([Self.reading("idle", nil)], thermalState: nil)
        #expect(extremes["idle"] == nil)
        #expect(extremes.mildestThermalState == nil)
        let rows = extremes.rows([Self.reading("idle", nil)])
        #expect(rows.count == 1 && rows[0].note == "idle")
    }

    @Test func keepsTheRowOfAChannelThatStopsReporting() {
        var extremes = SensorExtremes(since: Date())
        let first = [Self.reading("b", 30, rank: 1), Self.reading("a", 40, rank: 0)]
        extremes.record(first, thermalState: nil)
        #expect(extremes.rows(first).map(\.id) == ["b", "a"], "a full set is returned as given")
        let second = [Self.reading("b", 31, rank: 1)]
        extremes.record(second, thermalState: nil)
        let rows = extremes.rows(second)
        #expect(rows.map(\.id) == ["a", "b"])
        #expect(rows[0].value == nil && rows[0].note == "no reading")
        #expect(extremes["a"]?.highest == 40, "its range stays")
    }

    @Test func resetStartsOverFromTheResetPoint() {
        var extremes = SensorExtremes(since: Date(timeIntervalSince1970: 0))
        extremes.record([Self.reading("a", 90), Self.reading("gone", 1)], thermalState: .serious)
        let now = Date(timeIntervalSince1970: 100)
        extremes.reset(at: now)
        #expect(extremes.since == now && extremes.samples == 0 && extremes.ranges.isEmpty)
        #expect(extremes.worstThermalState == nil)
        extremes.record([Self.reading("a", 50)], thermalState: .nominal)
        #expect(extremes["a"]?.highest == 50)
        #expect(extremes.rows([Self.reading("a", 50)]).map(\.id) == ["a"], "channels from before the reset are forgotten")
        #expect(extremes.worstThermalState == .nominal)
    }

    @Test func reportsRangesInTableShape() throws {
        var extremes = SensorExtremes(since: Date(timeIntervalSince1970: 0))
        extremes.record([Self.reading("a", 40), Self.reading("b", nil)], thermalState: .fair)
        extremes.record([Self.reading("a", 45), Self.reading("b", nil)], thermalState: .nominal)
        let report = SensorExtremesReport(extremes: extremes, rows: [Self.reading("a", 45), Self.reading("b", nil)],
                                          thermalState: .nominal, until: Date(timeIntervalSince1970: 2), interval: 1, sensors: nil)
        #expect(report.rows.map(\.lowest) == [40, nil])
        #expect(report.rows.map(\.samples) == [2, 0])
        #expect(report.thermalPressure.worst == .fair && report.thermalPressure.mildest == .nominal)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SensorExtremesReport.self, from: encoder.encode(report))
        #expect(decoded.rows.map(\.reading) == report.rows.map(\.reading))
        #expect(decoded.since == Date(timeIntervalSince1970: 0))
    }

    // MARK: - Readings and units

    @Test func dropsNonFiniteValuesAndKeepsNotesOnlyWithoutOne() {
        #expect(Self.reading("a", .infinity).value == nil)
        #expect(Self.reading("a", .infinity).note == "idle")
        #expect(Self.reading("a", 3).note == nil)
    }

    @Test func formatsEachUnit() {
        #expect(SensorUnit.celsius.format(41.63) == "41.6 °C")
        #expect(SensorUnit.rpm.format(950) == "950 rpm")
        #expect(SensorUnit.megahertz.format(3_130) == "3.13 GHz")
        #expect(SensorUnit.megahertz.format(912) == "912 MHz")
        #expect(SensorUnit.fraction.format(0.1694) == "16.9%")
        #expect(SensorUnit.watts.format(0.412) == "412 mW")
        #expect(SensorUnit.watts.format(-12.34) == "\u{2212}12.3 W")
        #expect(SensorUnit.watts.format(0.0001) == "0 W")
        #expect(SensorUnit.volts.format(27.873) == "27.87 V")
        #expect(SensorUnit.amperes.format(-0.52) == "\u{2212}520 mA")
        #expect(SensorUnit.amperes.format(1.5) == "1.50 A")
        #expect(SensorUnit.celsius.format(.nan) == "—")
    }

    @Test func ordersGroupsByPartOfTheMac() {
        #expect(SensorGroup.allCases.sorted() == SensorGroup.allCases)
        #expect(SensorGroup.chip < SensorGroup.cpu && SensorGroup.power < SensorGroup.fans)
        #expect(ThermalState.critical.severity == 3 && ThermalState.nominal.title == "Nominal")
    }

    // MARK: - Sensor names and rails

    @Test func classifiesBlockSensorsIntoTheirParts() {
        #expect(SensorModel.classify("pACC MTR Temp Sensor2")?.label == "Performance cores 2")
        #expect(SensorModel.classify("pACC MTR Temp Sensor2")?.group == .cpu)
        #expect(SensorModel.classify("eACC MTR Temp Sensor0")?.group == .cpu)
        #expect(SensorModel.classify("GPU MTR Temp Sensor4")?.group == .gpu)
        #expect(SensorModel.classify("ANE MTR Temp Sensor1")?.group == .neuralEngine)
        #expect(SensorModel.classify("SOC MTR Temp Sensor0")?.group == .chip)
        #expect(SensorModel.classify("PMGR SOC Die Temp Sensor1")?.label == "Power manager 1")
        #expect(SensorModel.classify("ISP MTR Temp Sensor5")?.group == .other)
        #expect(SensorModel.classify("GPU MTR Temp Sensor") == nil, "no number, no row")
        #expect(SensorModel.classify("PMU tdie3")?.group == .chip)
        #expect(SensorModel.classify("NAND CH0 temp")?.group == .storage)
        #expect(SensorModel.classify("gas gauge battery")?.group == .battery)
    }

    @Test func keepsOnlyPlausibleRailReadings() {
        #expect(SMCRail.rail(key: "VD0R", label: "DC input voltage", unit: .volts, value: 27.87)?.value == 27.87)
        #expect(SMCRail.rail(key: "VD0R", label: "DC input voltage", unit: .volts, value: 0)?.value == 0)
        #expect(SMCRail.rail(key: "VD0R", label: "DC input voltage", unit: .volts, value: 400) == nil)
        #expect(SMCRail.rail(key: "ID0R", label: "DC input current", unit: .amperes, value: -1) == nil)
        #expect(SMCRail.rail(key: "ID0R", label: "DC input current", unit: .amperes, value: .nan) == nil)
        #expect(SMCRail.rail(key: "ID0R", label: "DC input current", unit: .amperes, value: nil) == nil)
        #expect(SMCRail.rail(key: "XXXX", label: "Unknown", unit: .watts, value: 3) == nil, "no plausible range, no rail")
    }
}
