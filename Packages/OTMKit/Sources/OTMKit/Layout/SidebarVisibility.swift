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

    /// `windowWidth` is the width the window opens at, when it's known
    /// before the window is measured (`openingWidth(savedFrame:)`), so a
    /// window that opens narrow never shows the sidebar at all.
    public init(hiddenByUser: Bool = false, windowWidth: Double? = nil) {
        self.hiddenByUser = hiddenByUser
        isNarrow = windowWidth.map(Self.isNarrow(width:))
    }

    /// The width in a window's saved frame, as AppKit keeps it under
    /// "NSWindow Frame <name>": "x y width height" and then the screen's
    /// frame. Nil when there's none or it doesn't read.
    public static func openingWidth(savedFrame: String?) -> Double? {
        guard let fields = savedFrame?.split(separator: " "), fields.count >= 4,
              let width = Double(fields[2]), width > 0 else { return nil }
        return width
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
