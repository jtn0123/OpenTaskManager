@testable import OTMKit
import Testing

struct HiddenSidebarFocusTests {
    @Test func whatThePageFocusedStays() {
        #expect(HiddenSidebarFocus.move(from: .content, tableReady: true) == .keep)
        #expect(HiddenSidebarFocus.move(from: .content, tableReady: false) == .keep)
        #expect(HiddenSidebarFocus.isSettled(.keep, from: .content))
    }

    @Test func theTableTakesFocusNobodyHolds() {
        for place in [HiddenSidebarFocus.Place.nowhere, .hiddenSidebar, .toolbarButton] {
            #expect(HiddenSidebarFocus.move(from: place, tableReady: true) == .table)
            #expect(HiddenSidebarFocus.isSettled(.table, from: place))
        }
    }

    @Test func withoutATableTheToggleLosesItsRing() {
        #expect(HiddenSidebarFocus.move(from: .toolbarButton, tableReady: false) == .clear)
        #expect(HiddenSidebarFocus.move(from: .hiddenSidebar, tableReady: false) == .clear)
        #expect(HiddenSidebarFocus.move(from: .nowhere, tableReady: false) == .keep)
    }

    @Test func keepsLookingUntilThePageHasIt() {
        // A table still loading may arrive, and the focus may yet fall to the toolbar.
        #expect(!HiddenSidebarFocus.isSettled(.keep, from: .nowhere))
        #expect(!HiddenSidebarFocus.isSettled(.clear, from: .toolbarButton))
        #expect(!HiddenSidebarFocus.isSettled(.clear, from: .hiddenSidebar))
    }
}
