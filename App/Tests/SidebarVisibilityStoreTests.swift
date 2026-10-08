import Foundation
import SwiftUI
import Testing

@MainActor
struct SidebarVisibilityStoreTests {
    @Test func savedNarrowFrameStartsHiddenWithoutSavingAUserHide() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("210 148 820 760 0 0 1600 970", forKey: "NSWindow Frame main")
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            #expect(sidebar.isNarrow == true)
            #expect(sidebar.columnVisibility == .detailOnly)
            sidebar.window(isNarrow: false)
            #expect(sidebar.columnVisibility == .all)
            #expect(defaults.persistentDomain(forName: suite)?["sidebarHidden"] == nil)
        }
    }

    @Test func splitViewHideInAWideWindowSurvivesResizeAndRelaunch() throws {
        try withIsolatedDefaults { defaults, _ in
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            sidebar.window(isNarrow: false)
            sidebar.columnVisibility = .detailOnly
            #expect(defaults.bool(forKey: "sidebarHidden"))
            sidebar.window(isNarrow: true)
            sidebar.window(isNarrow: false)
            #expect(!sidebar.isShown)
            #expect(!SidebarVisibilityStore(defaults: defaults).isShown)
            sidebar.columnVisibility = .all
            #expect(sidebar.isShown)
            #expect(!defaults.bool(forKey: "sidebarHidden"))
        }
    }

    @Test func showingInANarrowWindowLastsOnlyUntilCrossingTheBreakpoint() throws {
        try withIsolatedDefaults { defaults, suite in
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            sidebar.window(isNarrow: true)
            sidebar.columnVisibility = .all
            sidebar.window(isNarrow: true)
            #expect(sidebar.isShown)
            sidebar.window(isNarrow: false)
            sidebar.window(isNarrow: true)
            #expect(!sidebar.isShown)
            #expect(defaults.persistentDomain(forName: suite)?["sidebarHidden"] == nil)
        }
    }

    @Test func showingNarrowClearsAnEarlierWideHide() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set(true, forKey: "sidebarHidden")
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            sidebar.window(isNarrow: true)
            sidebar.columnVisibility = .doubleColumn
            #expect(sidebar.columnVisibility == .all)
            #expect(!defaults.bool(forKey: "sidebarHidden"))
            sidebar.columnVisibility = .detailOnly
            #expect(!sidebar.isShown)
            sidebar.window(isNarrow: false)
            #expect(sidebar.isShown)
        }
    }

    @Test func openingReadsSettingsOnceAndRepeatedChoicesDoNotRewriteThem() throws {
        try withIsolatedDefaults { defaults, _ in
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            #expect(sidebar.isNarrow == nil)
            #expect(sidebar.isShown)
            defaults.set(true, forKey: "sidebarHidden")
            defaults.set("0 0 820 760", forKey: "NSWindow Frame main")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            sidebar.columnVisibility = .all
            #expect(sidebar.isShown)
            #expect(sidebar.isNarrow == nil)
            #expect(defaults.bool(forKey: "sidebarHidden"))
        }
    }

    @Test(arguments: ["", "0 0 wide 760", "0 0 0 760"])
    func missingOrInvalidSavedFrameWaitsForTheWindowMeasurement(frame: String) throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set(frame, forKey: "NSWindow Frame main")
            let sidebar = SidebarVisibilityStore(defaults: defaults)
            #expect(sidebar.isNarrow == nil)
            #expect(sidebar.isShown)
            sidebar.window(isNarrow: true)
            #expect(!sidebar.isShown)
        }
    }
}
