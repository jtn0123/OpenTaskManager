import Foundation

/// Whether a page that just opened should take the keyboard focus off the
/// control AppKit gave it. When a window first becomes key, or a page's
/// controls arrive, AppKit hands the focus to the first control in the key
/// view loop: on the History page, its range picker, which then wears a
/// focus ring (with keyboard navigation on) as if the user had tabbed to it.
/// Such a ring is taken away so the page opens with nothing ringed. Focus
/// the user moved (a key pressed or a click since the page opened), a text
/// field being typed in, and anything outside the page (the sidebar's list,
/// the toolbar) stay where they are.
public enum OpeningFocus {
    /// What has the focus.
    public enum Holder: Equatable, Sendable {
        /// Nothing in particular: the window itself.
        case nothing
        /// A text field or text view, which may be typed in.
        case text
        /// A button, picker, checkbox or other control.
        case control
        /// Anything else: a table, a scroll view.
        case other
    }

    /// Whether to take the focus from `holder`, which is (or isn't) on the
    /// page, given whether the user has acted since the page opened.
    public static func clears(_ holder: Holder, onPage: Bool, userActed: Bool) -> Bool {
        !userActed && onPage && holder == .control
    }

    /// Whether to stop looking: the user acted, or the focus is somewhere it
    /// stays (nothing, text, or something other than a control). Until then
    /// AppKit may still hand a control the focus a moment later.
    public static func isSettled(_ holder: Holder, userActed: Bool) -> Bool {
        userActed || holder == .text || holder == .other
    }
}
