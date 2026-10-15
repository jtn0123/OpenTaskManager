import OTMKit
import SwiftUI

/// The window's sidebar choice, read once at opening. Only the user's
/// lasting hide is saved; measuring a narrow window never changes that setting.
@MainActor @Observable
final class SidebarVisibilityStore {
    @ObservationIgnored private let defaults: UserDefaults
    private var visibility: SidebarVisibility

    /// `openingWidth` is the width the window opens at (`MainWindowFrame.opening`).
    init(defaults: UserDefaults = .standard, openingWidth: Double) {
        self.defaults = defaults
        visibility = SidebarVisibility(hiddenByUser: Settings.sidebarHidden.get(in: defaults), windowWidth: openingWidth)
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, openingWidth: MainWindowFrame.opening(defaults: defaults).width)
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
            Settings.sidebarHidden.set(visibility.hiddenByUser, in: defaults)
        }
    }
}
