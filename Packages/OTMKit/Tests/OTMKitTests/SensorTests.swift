@testable import OTMKit
import Testing

struct SensorTests {
    @Test func classifiesTheSensorsTheAppShows() {
        #expect(SensorModel.classify("PMU tdie3")?.kind == .chip)
        #expect(SensorModel.classify("PMU tdie3")?.label == "Die 3")
        #expect(SensorModel.classify("NAND CH0 temp")?.kind == .storage)
        #expect(SensorModel.classify("NAND CH0 temp")?.label == "SSD channel 0")
        #expect(SensorModel.classify("gas gauge battery")?.kind == .battery)
        #expect(SensorModel.classify("PMU tcal") == nil)
        #expect(SensorModel.classify("PMU tdev1") == nil)
        #expect(SensorModel.classify("PMU tdieX") == nil)
    }

    @Test func keepsTheHottestReadingPerSensorAndDropsNonsense() {
        let temperatures = SensorModel.temperatures(from: [
            ("PMU tdie10", 61.2), ("PMU tdie2", 60.1), ("PMU tdie2", 61.4),
            ("gas gauge battery", 33.0), ("gas gauge battery", 34.7),
            ("NAND CH0 temp", 36.0), ("PMU tdev1", -9201.1), ("PMU tdie1", -9201.1), ("PMU tcal", 51.8),
        ])
        #expect(temperatures.map(\.label) == ["Die 2", "Die 10", "SSD channel 0", "Battery"])
        #expect(temperatures.first { $0.label == "Die 2" }?.celsius == 61.4)
        #expect(temperatures.first { $0.kind == .battery }?.celsius == 34.7)
    }

    @Test func summarisesByKind() {
        let sample = SensorSample(temperatures: SensorModel.temperatures(from: [
            ("PMU tdie1", 60), ("PMU tdie2", 70), ("NAND CH0 temp", 40),
        ]), fans: [])
        #expect(sample.hottest(.chip) == 70)
        #expect(sample.average(.chip) == 65)
        #expect(sample.hottest(.battery) == nil)
        #expect(!sample.isEmpty)
    }

    @Test func fanShareIsOfItsMaximum() {
        #expect(SensorSample.Fan(id: 0, rpm: 2675, minimumRPM: 1350, maximumRPM: 5350).shareOfMaximum == 0.5)
        // At its minimum a fan is turning, so it doesn't read as 0%.
        let slowest = SensorSample.Fan(id: 0, rpm: 1356, minimumRPM: 1350, maximumRPM: 5349)
        #expect(Format.percent(slowest.shareOfMaximum ?? 0) == "25%")
        #expect(!slowest.isStopped)
        #expect(SensorSample.Fan(id: 0, rpm: 0, minimumRPM: 1350, maximumRPM: 5350).isStopped)
        #expect(SensorSample.Fan(id: 0, rpm: 0, minimumRPM: 1350, maximumRPM: 5350).shareOfMaximum == 0)
        // Past its published maximum it reads as full.
        #expect(SensorSample.Fan(id: 0, rpm: 6000, minimumRPM: 1350, maximumRPM: 5350).shareOfMaximum == 1)
        // Without a maximum there's no scale; the minimum alone isn't one.
        #expect(SensorSample.Fan(id: 0, rpm: 2000, minimumRPM: 1350, maximumRPM: nil).shareOfMaximum == nil)
        #expect(SensorSample.Fan(id: 0, rpm: 2000, minimumRPM: nil, maximumRPM: 0).shareOfMaximum == nil)
    }
}
