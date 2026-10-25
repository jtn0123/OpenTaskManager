import AppKit
import OTMKit
import Testing

@MainActor
struct MainWindowFrameTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 970)

    private func opening(_ defaults: UserDefaults, arguments: [String: Any] = [:], screens: [CGRect]? = nil,
                         main: CGRect? = nil) -> CGRect {
        MainWindowFrame.opening(defaults: defaults, arguments: arguments, screens: screens ?? [screen], main: main ?? screen)
    }

    @Test func aFirstWindowOpensAtTheDefaultWithRoomForTheSidebar() throws {
        try withIsolatedDefaults { defaults, _ in
            let frame = opening(defaults)
            #expect(frame == WindowPlacement.defaultFrame(in: screen))
            #expect(!SidebarVisibility.isNarrow(width: frame.width))
        }
    }

    @Test func aMovedOrResizedWindowOpensWhereItWasLeft() throws {
        try withIsolatedDefaults { defaults, suite in
            let left = CGRect(x: 120, y: 80, width: 990, height: 700)
            MainWindowFrame.save(left, defaults: defaults, arguments: [:])
            #expect(defaults.persistentDomain(forName: suite)?["mainWindowFrame"] as? String == "120 80 990 700")
            #expect(opening(defaults) == left)
        }
    }

    @Test func aWindowLeftOnAScreenThatsGoneOpensOnTheMainOne() throws {
        try withIsolatedDefaults { defaults, _ in
            MainWindowFrame.save(CGRect(x: 1700, y: 100, width: 1000, height: 700), defaults: defaults, arguments: [:])
            let frame = opening(defaults)
            #expect(screen.contains(frame))
            #expect(frame.size == CGSize(width: 1000, height: 700))
        }
    }

    @Test func aLaunchArgumentPlacesTheWindowForThatRunAndNothingIsSaved() throws {
        try withIsolatedDefaults { defaults, suite in
            MainWindowFrame.save(CGRect(x: 120, y: 80, width: 990, height: 700), defaults: defaults, arguments: [:])
            let arguments = ["openWindowFrame": "210 148 820 760"]
            #expect(opening(defaults, arguments: arguments) == CGRect(x: 210, y: 148, width: 820, height: 760))
            MainWindowFrame.save(CGRect(x: 210, y: 148, width: 820, height: 760), defaults: defaults, arguments: arguments)
            #expect(defaults.persistentDomain(forName: suite)?["mainWindowFrame"] as? String == "120 80 990 700")
        }
    }

    @Test(arguments: ["", "0 0 wide 760", "0 0 0 760"])
    func anUnreadableSavedFrameOpensAtTheDefault(saved: String) throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set(saved, forKey: "mainWindowFrame")
            #expect(opening(defaults) == WindowPlacement.defaultFrame(in: screen))
        }
    }

    @Test func withNoScreenTheSavedFrameOrTheDefaultMinimumIsUsed() throws {
        try withIsolatedDefaults { defaults, _ in
            let none = MainWindowFrame.opening(defaults: defaults, arguments: [:], screens: [], main: nil)
            #expect(none.size == WindowPlacement.defaultMinimum)
            MainWindowFrame.save(CGRect(x: 10, y: 20, width: 900, height: 600), defaults: defaults, arguments: [:])
            let saved = MainWindowFrame.opening(defaults: defaults, arguments: [:], screens: [], main: nil)
            #expect(saved == CGRect(x: 10, y: 20, width: 900, height: 600))
        }
    }

    @Test func appKitsFramesAndSavedStateNoLongerOpenTheWindow() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("210 148 820 760 0 0 1600 970 ", forKey: MainWindowFrame.appKitKey)
            #expect(opening(defaults) == WindowPlacement.defaultFrame(in: screen))
            MainWindowFrame.ignoreSavedWindowState(defaults: defaults)
            #expect(defaults.persistentDomain(forName: suite)?[MainWindowFrame.appKitKey] == nil)
            #expect(defaults.bool(forKey: MainWindowFrame.ignoresSavedStateKey))
            // Only for this run: nothing is written to the saved settings.
            #expect(defaults.persistentDomain(forName: suite)?[MainWindowFrame.ignoresSavedStateKey] == nil)
        }
    }
}
