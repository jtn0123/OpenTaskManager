import OTMKit
import SwiftUI

/// The window's sidebar choice, read once at opening. Only the user's
/// lasting hide is saved; measuring a narrow window never changes that setting.
@MainActor @Observable
final class SidebarVisibilityStore {
    private static let hiddenKey = "sidebarHidden"
    @ObservationIgnored private let defaults: UserDefaults
    private var visibility: SidebarVisibility

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        visibility = SidebarVisibility(
            hiddenByUser: defaults.bool(forKey: Self.hiddenKey),
            windowWidth: SidebarVisibility.openingWidth(savedFrame: defaults.string(forKey: "NSWindow Frame main"))
        )
    }

    var isShown: Bool { visibility.isShown }
    var isNarrow: Bool? { visibility.isNarrow }

    /// The split view's button and View menu both go through the same choice.
    var columnVisibility: NavigationSplitViewVisibility {
        get { isShown ? .all : .detailOnly }
        set { userSets(shown: newValue != .detailOnly) }
    }

    func window(isNarrow: Bool) { visibility.window(isNarrow: isNarrow) }

    func userSets(shown: Bool) {
        let wasHidden = visibility.hiddenByUser
        visibility.userSets(shown: shown)
        if visibility.hiddenByUser != wasHidden {
            defaults.set(visibility.hiddenByUser, forKey: Self.hiddenKey)
        }
    }
}
