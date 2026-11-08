@testable import OTMKit
import Testing

struct CPUScaleTests {
    @Test func perCoreModeKeepsActivityMonitorFigures() {
        let scale = CPUScale(relativeToSystem: false, logicalCores: 18)
        #expect(scale.value(1_200) == 1_200)
        #expect(scale.format(1_200) == "1200.0%")
        #expect(scale.shownStep == 0.1)
    }

    @Test func wholeSystemModeDividesByCoreCountAndCapsAtOneHundred() {
        let scale = CPUScale(relativeToSystem: true, logicalCores: 8)
        #expect(scale.value(400) == 50)
        #expect(scale.value(1_200) == 100)
        #expect(scale.format(1) == "0.1%")
        #expect(scale.shownStep == 0.8)
    }

    @Test(arguments: [0, -1, -8])
    func unknownCoreCountsUseOneCore(cores: Int) {
        let scale = CPUScale(relativeToSystem: true, logicalCores: cores)
        #expect(scale.value(40) == 40)
        #expect(scale.value(400) == 100)
        #expect(scale.format(40) == "40.0%")
        #expect(scale.shownStep == 0.1)
    }

    @Test(arguments: [1, 8, 18])
    func sortingStepMatchesOneDisplayedTenthOfAPercent(cores: Int) {
        let scale = CPUScale(relativeToSystem: true, logicalCores: cores)
        #expect(abs(scale.value(scale.shownStep) - 0.1) < 1e-12)
    }
}
