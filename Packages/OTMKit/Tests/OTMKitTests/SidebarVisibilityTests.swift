@testable import OTMKit
import Testing

struct SidebarVisibilityTests {
    @Test func showsUntilTheWindowIsMeasured() {
        #expect(SidebarVisibility().isShown)
    }

    @Test func narrowWindowsHideItAndWideOnesBringItBack() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(1180)
        #expect(sidebar.isShown)
        sidebar.windowWidth(820)
        #expect(!sidebar.isShown)
        sidebar.windowWidth(860)
        #expect(!sidebar.isShown)
        sidebar.windowWidth(900)
        #expect(sidebar.isShown)
    }

    @Test func aWindowOpenedNarrowStartsWithoutIt() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(820)
        #expect(!sidebar.isShown)
    }

    @Test func aWindowKnownToOpenNarrowNeverShowsIt() {
        var sidebar = SidebarVisibility(windowWidth: 820)
        #expect(!sidebar.isShown)
        // The first measurement agrees, so nothing changes.
        let before = sidebar
        sidebar.windowWidth(820)
        #expect(sidebar == before)
        #expect(SidebarVisibility(windowWidth: 1180).isShown)
        #expect(!SidebarVisibility(hiddenByUser: true, windowWidth: 1180).isShown)
    }

    @Test func aWrongOpeningWidthIsPutRightByTheFirstMeasurement() {
        var sidebar = SidebarVisibility(windowWidth: 820)
        sidebar.windowWidth(1180)
        #expect(sidebar.isShown)
        var wide = SidebarVisibility(windowWidth: 1180)
        wide.windowWidth(820)
        #expect(!wide.isShown)
    }

    @Test func readsTheWidthFromASavedWindowFrame() {
        #expect(SidebarVisibility.openingWidth(savedFrame: "210 148 820 760 0 0 1600 970 ") == 820)
        #expect(SidebarVisibility.openingWidth(savedFrame: "-40.5 12 1180.5 760 0 0 1600 970") == 1180.5)
        #expect(SidebarVisibility.openingWidth(savedFrame: nil) == nil)
        #expect(SidebarVisibility.openingWidth(savedFrame: "") == nil)
        #expect(SidebarVisibility.openingWidth(savedFrame: "210 148 wide 760") == nil)
        #expect(SidebarVisibility.openingWidth(savedFrame: "210 148 820") == nil)
        #expect(SidebarVisibility.openingWidth(savedFrame: "210 148 0 760 0 0 1600 970") == nil)
    }

    @Test func showingItInANarrowWindowLastsUntilTheWindowCrossesTheBreakpoint() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(820)
        sidebar.userSets(shown: true)
        #expect(sidebar.isShown)
        // Resizing within the narrow range keeps it.
        sidebar.windowWidth(880)
        #expect(sidebar.isShown)
        sidebar.windowWidth(1000)
        #expect(sidebar.isShown)
        // Narrow again: the window decides once more.
        sidebar.windowWidth(820)
        #expect(!sidebar.isShown)
        #expect(!sidebar.hiddenByUser)
    }

    @Test func hidingItInAWideWindowSticksAtEveryWidth() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(1180)
        sidebar.userSets(shown: false)
        #expect(sidebar.hiddenByUser)
        sidebar.windowWidth(820)
        sidebar.windowWidth(1180)
        #expect(!sidebar.isShown)
        sidebar.userSets(shown: true)
        #expect(sidebar.isShown)
        #expect(!sidebar.hiddenByUser)
    }

    @Test func hidingItInANarrowWindowAgreesWithTheWindow() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(820)
        sidebar.userSets(shown: true)
        sidebar.userSets(shown: false)
        #expect(!sidebar.isShown)
        #expect(!sidebar.hiddenByUser)
        sidebar.windowWidth(1180)
        #expect(sidebar.isShown)
    }

    @Test func aSavedHideHoldsFromLaunch() {
        var sidebar = SidebarVisibility(hiddenByUser: true)
        sidebar.windowWidth(1180)
        #expect(!sidebar.isShown)
        // Showing it in a narrow window clears the saved choice.
        sidebar.windowWidth(820)
        sidebar.userSets(shown: true)
        #expect(sidebar.isShown)
        #expect(!sidebar.hiddenByUser)
    }

    @Test func settingWhatAlreadyShowsChangesNothing() {
        var sidebar = SidebarVisibility()
        sidebar.windowWidth(820)
        let before = sidebar
        sidebar.userSets(shown: false)
        #expect(sidebar == before)
    }
}
