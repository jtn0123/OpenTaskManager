@testable import OTMKit
import Testing

struct PageTests {
    @Test(arguments: Page.allCases)
    func savedNamesAndLaunchNamesRoundTrip(page: Page) {
        #expect(Page.starting(openPage: nil, savedPage: page.rawValue) == page)
        #expect(Page.starting(openPage: page.rawValue, savedPage: "History") == page)
        #expect(page.id == page.rawValue)
    }

    @Test func explicitPageWinsOverTheSavedPage() {
        #expect(Page.starting(openPage: "Storage", savedPage: "Processes") == .storage)
        #expect(Page.starting(openPage: nil, savedPage: nil) == .overview)
    }

    @Test(arguments: ["", "storage", "Unknown", " History "])
    func invalidNamesOpenOverview(name: String) {
        #expect(Page.starting(openPage: name, savedPage: "Processes") == .overview)
        #expect(Page.starting(openPage: nil, savedPage: name) == .overview)
    }

    @Test func shortcutsFollowSidebarOrderAndStopAtNine() {
        #expect(Page.allCases.map(\.rawValue) == [
            "Overview", "Processes", "Performance", "History", "Connections", "Startup",
            "Apps", "Users", "System", "Drivers", "Storage",
        ])
        #expect(Page.allCases.compactMap(\.shortcutNumber) == Array(1...9))
        #expect(Page.drivers.shortcutNumber == nil)
        #expect(Page.storage.shortcutNumber == nil)
    }
}
