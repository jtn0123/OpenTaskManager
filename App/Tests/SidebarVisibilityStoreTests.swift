import Foundation
import SwiftUI
import Testing

@MainActor
struct SidebarVisibilityStoreTests {
    @Test func aWindowOpeningNarrowStartsHiddenWithoutSavingAUserHide() throws {
        try withIsolatedDefaults { defaults, suite in
            let sidebar = SidebarVisibilityStore(defaults: defaults, openingWidth: 820)
            #expect(sidebar.isNarrow == true)
            #expect(sidebar.columnVisibility == .detailOnly)
            sidebar.window(isNarrow: false)
            #expect(sidebar.columnVisibility == .all)
            #expect(defaults.persistentDomain(forName: suite)?["sidebarHidden"] == nil)
        }
    }

    @Test func splitViewHideInAWideWindowSurvivesResizeAndRelaunch() throws {
        try withIsolatedDefaults { defaults, _ in
            let sidebar = SidebarVisibilityStore(defaults: defaults, openingWidth: 1180)
            sidebar.window(isNarrow: false)
            sidebar.columnVisibility = .detailOnly
            #expect(defaults.bool(forKey: "sidebarHidden"))
            sidebar.window(isNarrow: true)
            sidebar.window(isNarrow: false)
            #expect(!sidebar.isShown)
            #expect(!SidebarVisibilityStore(defaults: defaults, openingWidth: 1180).isShown)
            sidebar.columnVisibility = .all
            #expect(sidebar.isShown)
            #expect(!defaults.bool(forKey: "sidebarHidden"))
        }
    }

    @Test func showingInANarrowWindowLastsOnlyUntilCrossingTheBreakpoint() throws {
        try withIsolatedDefaults { defaults, suite in
            let sidebar = SidebarVisibilityStore(defaults: defaults, openingWidth: 1180)
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
            let sidebar = SidebarVisibilityStore(defaults: defaults, openingWidth: 1180)
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
            let sidebar = SidebarVisibilityStore(defaults: defaults, openingWidth: 1180)
            #expect(sidebar.isNarrow == false)
            #expect(sidebar.isShown)
            defaults.set(true, forKey: "sidebarHidden")
            defaults.set("0 0 820 760", forKey: "mainWindowFrame")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            sidebar.columnVisibility = .all
            #expect(sidebar.isShown)
            #expect(sidebar.isNarrow == false)
            #expect(defaults.bool(forKey: "sidebarHidden"))
        }
    }

    @Test func opensFromTheSavedWindowFrame() throws {
        try withIsolatedDefaults { defaults, _ in
            MainWindowFrame.save(CGRect(x: 0, y: 0, width: 820, height: 760), defaults: defaults, arguments: [:])
            #expect(SidebarVisibilityStore(defaults: defaults).isNarrow == true)
            #expect(!SidebarVisibilityStore(defaults: defaults).isShown)
        }
    }
}
