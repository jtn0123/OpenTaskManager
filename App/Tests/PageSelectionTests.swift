import Foundation
import OTMKit
import Testing

@MainActor
struct PageSelectionTests {
    @Test func openingReadsTheSavedPageWithoutWritingIt() throws {
        try withIsolatedDefaults { defaults, suite in
            let fresh = PageSelection(defaults: defaults)
            #expect(fresh.page == .overview)
            #expect(defaults.persistentDomain(forName: suite)?["page"] == nil)
            defaults.set("History", forKey: "page")
            #expect(PageSelection(defaults: defaults).page == .history)
        }
    }

    @Test func openPageWinsOverPageAndSavedSettings() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("Processes", forKey: "page")
            defaults.setVolatileDomain(["openPage": "Storage", "page": "Apps"], forName: UserDefaults.argumentDomain)
            #expect(PageSelection(defaults: defaults).page == .storage)
            #expect(defaults.persistentDomain(forName: suite)?["page"] as? String == "Processes")
        }
    }

    @Test func pageArgumentOnlySetsTheStartingPageAndChangesStillSave() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("Processes", forKey: "page")
            defaults.setVolatileDomain(["page": "History"], forName: UserDefaults.argumentDomain)
            let selection = PageSelection(defaults: defaults)
            #expect(selection.page == .history)
            selection.page = .users
            #expect(selection.page == .users)
            // The argument domain still masks the saved setting. Read the suite itself.
            #expect(defaults.string(forKey: "page") == "History")
            #expect(defaults.persistentDomain(forName: suite)?["page"] as? String == "Users")
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            #expect(PageSelection(defaults: defaults).page == .users)
        }
    }

    @Test func invalidExplicitPageDoesNotFallBackToTheSavedPage() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("Processes", forKey: "page")
            defaults.setVolatileDomain(["openPage": "unknown"], forName: UserDefaults.argumentDomain)
            #expect(PageSelection(defaults: defaults).page == .overview)
        }
    }

    @Test func selectionsNeverFollowDefaultsOrEachOther() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("Processes", forKey: "page")
            let first = PageSelection(defaults: defaults)
            let second = PageSelection(defaults: defaults)
            first.page = .storage
            #expect(second.page == .processes)
            #expect(PageSelection(defaults: defaults).page == .storage)
            defaults.set("Apps", forKey: "page")
            defaults.setVolatileDomain(["openPage": "History"], forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(first.page == .storage)
            #expect(second.page == .processes)
        }
    }

    @Test func assigningTheSamePageDoesNotOverwriteAnotherCopiesSavedChoice() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("History", forKey: "page")
            let selection = PageSelection(defaults: defaults)
            defaults.set("Storage", forKey: "page")
            selection.page = .history
            #expect(defaults.string(forKey: "page") == "Storage")
            selection.page = .performance
            #expect(defaults.string(forKey: "page") == "Performance")
        }
    }
}
