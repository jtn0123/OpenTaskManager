@testable import OTMKit
import Testing

struct PowerEnergyTests {
    private func power(_ watts: Double?) -> PowerSample {
        PowerSample(systemWatts: watts, battery: nil, isLowPowerMode: false, thermalState: .nominal,
                    adapter: nil, systemWattsSource: nil, components: nil)
    }

    @Test func integratesMeasuredWattsUsingEachTicksDuration() {
        var energy = PowerEnergy()
        energy.add(power(10), interval: 2)
        energy.add(power(20), interval: 1)
        #expect(energy.joules == 40)
        #expect(energy.seconds == 3)
        #expect(energy.averageWatts == 40.0 / 3)
        #expect(energy.components.isEmpty)
    }

    @Test func sleepAndMissingReadingsNeverInventEnergy() {
        var energy = PowerEnergy()
        energy.add(power(10), interval: 0)
        energy.add(power(10), interval: 600)
        energy.add(power(nil), interval: 1)
        #expect(energy.joules == 0 && energy.seconds == 0)
        #expect(energy.averageWatts == nil)
        energy.add(power(10), interval: 1)
        #expect(energy.joules == 10 && energy.averageWatts == 10)
    }
}
