import Foundation

/// Values passed on the command line (`--args -openResource memory`), for
/// opening the app in a known state for screenshots. Read from the argument
/// domain only, so they never stick in saved settings.
enum LaunchArgument {
    static func string(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }

    /// Whether `-openSpeedTest start` is for the test or benchmark on
    /// `resource`'s Performance detail (an `-openResource` name: "cpu",
    /// "gpu", "disk", "network"): the requested resource's only, or the
    /// CPU's when none is requested, as the page opens on the CPU. The page
    /// shows the CPU for a frame on its way to another resource, so a card
    /// must ask this rather than start because it appeared.
    static func startsTest(on resource: String) -> Bool {
        string("openSpeedTest") == "start" && (string("openResource") ?? "cpu") == resource
    }

    /// Lets a table that has just appeared lay out before a request selects
    /// a row in it, as it would have before a click. A SwiftUI `Table` that
    /// first appears beside its details pane keeps its columns' ideal
    /// widths, so in a narrow window it scrolled sideways; one laid out at
    /// the full width narrows its columns to fit when the pane opens.
    static func afterTableLayout() async {
        try? await Task.sleep(for: .milliseconds(250))
    }
}
