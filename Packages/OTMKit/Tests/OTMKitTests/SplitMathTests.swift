@testable import OTMKit
import Testing

struct SplitMathTests {
    private func width(_ available: Double, list: Double = 700, preferred: Double = 320) -> Double? {
        SplitMath.inspectorWidth(available: available, listMinimum: list, preferred: preferred, minimum: 280, maximum: 480)
    }

    @Test func keepsThePreferredWidthWhenThereIsRoom() {
        #expect(width(1400) == 320)
    }

    @Test func narrowsTheInspectorBeforeTheList() {
        // 992 wide: the list keeps its 700 and the divider 1, leaving 291.
        #expect(width(992) == 291)
    }

    @Test func noRoomForBothMeansNoSideBySide() {
        #expect(width(980) == nil)
        #expect(width(0) == nil)
    }

    @Test func exactFitAtBothMinimums() {
        #expect(width(981) == 280)
    }

    @Test func preferredWidthIsKeptWithinBounds() {
        #expect(width(2000, preferred: 900) == 480)
        #expect(width(2000, preferred: 100) == 280)
    }
}
