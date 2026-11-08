@testable import OTMKit
import Testing

struct ContentColumnWidthTests {
    @Test func fitsTheWidestValueWithSlack() {
        // "Your LaunchAgents folder" at about 156 points, under a 50-point title.
        #expect(ContentColumnWidth.fitting(content: 156, header: 50, floor: 120, cap: 200) == 160)
    }

    @Test func fitsTheTitleWhenTheValuesAreShorter() {
        // "Universal" under "Architecture" and its sort arrow.
        #expect(ContentColumnWidth.fitting(content: 60, header: 104, floor: 85) == 104)
    }

    @Test func neverGoesUnderTheFloor() {
        #expect(ContentColumnWidth.fitting(content: 20, header: 40, floor: 45, cap: 100) == 45)
        // A cap under the floor gives way to it.
        #expect(ContentColumnWidth.fitting(content: 300, header: 40, floor: 120, cap: 100) == 120)
    }

    @Test func stopsAtTheCap() {
        // "Registered state unknown" and long schedules are cut, their tooltips whole.
        #expect(ContentColumnWidth.fitting(content: 190, header: 70, floor: 84, cap: 150) == 150)
    }

    @Test func anEmptyColumnStillFitsItsTitle() {
        #expect(ContentColumnWidth.fitting(content: 0, header: 70, floor: 45) == 70)
        #expect(ContentColumnWidth.fitting(content: 0, header: 0, floor: 45) == 45)
    }
}
