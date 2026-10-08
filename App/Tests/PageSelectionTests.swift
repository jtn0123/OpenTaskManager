import Foundation
import OTMKit
import Testing

@MainActor
struct PageSelectionTests {
    @Test func openingReadsTheSavedPageWithoutWritingIt() throws {
        try withIsolatedDefaults { defaults, suite in
            let fresh = PageSelection(defaults: defaults, arguments: [:])
            #expect(fresh.page == .overview)
            #expect(defaults.persistentDomain(forName: suite)?["page"] == nil)
            defaults.set("History", forKey: "page")
            #expect(PageSelection(defaults: defaults, arguments: [:]).page == .history)
        }
    }

    @Test func openPageWinsOverPageAndSavedSettings() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("Processes", forKey: "page")
            #expect(PageSelection(defaults: defaults, arguments: ["openPage": "Storage", "page": "Apps"]).page == .storage)
            #expect(defaults.persistentDomain(forName: suite)?["page"] as? String == "Processes")
        }
    }

    @Test func scheduleArgumentOpensStorageWithoutSavingThePage() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("Processes", forKey: "page")
            let selection = PageSelection(defaults: defaults, arguments: ["openStorageSchedule": "/Library"])
            #expect(selection.page == .storage)
            #expect(defaults.persistentDomain(forName: suite)?["page"] as? String == "Processes")
        }
    }

    @Test func pageArgumentOnlySetsTheStartingPageAndChangesStillSave() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("Processes", forKey: "page")
            let selection = PageSelection(defaults: defaults, arguments: ["page": "History"])
            #expect(selection.page == .history)
            selection.page = .users
            #expect(selection.page == .users)
            #expect(defaults.persistentDomain(forName: suite)?["page"] as? String == "Users")
            #expect(PageSelection(defaults: defaults, arguments: [:]).page == .users)
        }
    }

    @Test func invalidExplicitPageDoesNotFallBackToTheSavedPage() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("Processes", forKey: "page")
            #expect(PageSelection(defaults: defaults, arguments: ["openPage": "unknown"]).page == .overview)
        }
    }

    @Test func selectionsNeverFollowDefaultsOrEachOther() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("Processes", forKey: "page")
            let first = PageSelection(defaults: defaults, arguments: [:])
            let second = PageSelection(defaults: defaults, arguments: [:])
            first.page = .storage
            #expect(second.page == .processes)
            #expect(PageSelection(defaults: defaults, arguments: [:]).page == .storage)
            defaults.set("Apps", forKey: "page")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(first.page == .storage)
            #expect(second.page == .processes)
        }
    }

    @Test func assigningTheSamePageDoesNotOverwriteAnotherCopiesSavedChoice() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("History", forKey: "page")
            let selection = PageSelection(defaults: defaults, arguments: [:])
            defaults.set("Storage", forKey: "page")
            selection.page = .history
            #expect(defaults.string(forKey: "page") == "Storage")
            selection.page = .performance
            #expect(defaults.string(forKey: "page") == "Performance")
        }
    }
}
