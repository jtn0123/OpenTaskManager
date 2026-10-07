import Foundation

/// Whether the window's sidebar shows. It steps aside by itself when the
/// window gets narrower than `breakpoint`, so the page gets its width, and
/// comes back when the window widens again. What the user does wins:
/// hiding it in a wide window keeps it hidden at any width (and is worth
/// saving), and showing it in a narrow window keeps it there until the
/// window next crosses the breakpoint. Hiding it in a narrow window agrees
/// with the window, so it comes back on widening as before.
public struct SidebarVisibility: Equatable, Sendable {
    /// Window widths below this hide the sidebar: at the narrowest window
    /// (820 points) it took about a fifth of the width from the page.
    public static let breakpoint: Double = 900

    /// The user hid the sidebar in a wide window.
    public private(set) var hiddenByUser: Bool
    /// Whether the window is narrower than the breakpoint; nil until it's measured.
    public private(set) var isNarrow: Bool?
    /// The user showed the sidebar while the window was narrow.
    private var shownWhileNarrow = false

    public init(hiddenByUser: Bool = false) {
        self.hiddenByUser = hiddenByUser
    }

    public var isShown: Bool {
        !hiddenByUser && (isNarrow != true || shownWhileNarrow)
    }

    /// Whether a window `width` points wide is narrow enough to hide the sidebar.
    public static func isNarrow(width: Double) -> Bool {
        width < breakpoint
    }

    /// The window is `width` points wide. Only crossing the breakpoint changes anything.
    public mutating func windowWidth(_ width: Double) {
        window(isNarrow: Self.isNarrow(width: width))
    }

    /// The window is, or isn't, narrower than the breakpoint.
    public mutating func window(isNarrow narrow: Bool) {
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        shownWhileNarrow = false
    }

    /// The user showed or hid the sidebar: its toolbar button, or View > Hide Sidebar.
    public mutating func userSets(shown: Bool) {
        guard shown != isShown else { return }
        if shown {
            hiddenByUser = false
            shownWhileNarrow = isNarrow == true
        } else if isNarrow == true {
            shownWhileNarrow = false
        } else {
            hiddenByUser = true
        }
    }
}
