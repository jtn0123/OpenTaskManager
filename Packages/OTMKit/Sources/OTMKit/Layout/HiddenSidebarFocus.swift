import Foundation

/// Where the keyboard focus goes while the window's sidebar is hidden. With
/// the sidebar's list out of the way, the focus would otherwise fall to the
/// toolbar's first button, the sidebar toggle, which then wears a focus ring
/// (with keyboard navigation on). The page's main table takes it instead,
/// on the pages built around one; elsewhere nothing has it.
public enum HiddenSidebarFocus {
    /// Where the focus is now.
    public enum Place: Equatable, Sendable {
        /// Nothing in particular: the window itself.
        case nowhere
        /// A view in the hidden sidebar, its list.
        case hiddenSidebar
        /// A toolbar button: where the focus falls when what had it goes.
        case toolbarButton
        /// Something the user or the page chose: a control on the page, or
        /// a toolbar search field being typed in.
        case content
    }

    public enum Move: Equatable, Sendable {
        case keep
        /// Give the focus to the page's main table.
        case table
        /// Take the focus from where it is, leaving nothing focused.
        case clear
    }

    /// What to do with the focus at `place`, when the page's main table is
    /// (or isn't) on screen to take it.
    public static func move(from place: Place, tableReady: Bool) -> Move {
        switch place {
        case .content: .keep
        case .nowhere: tableReady ? .table : .keep
        case .hiddenSidebar, .toolbarButton: tableReady ? .table : .clear
        }
    }

    /// Whether the focus has found its place, so there's no need to look
    /// again: the page has it, or its table was just given it. Until then
    /// a table may still arrive (pages that read their list first), or the
    /// focus fall to the toolbar a moment later.
    public static func isSettled(_ move: Move, from place: Place) -> Bool {
        place == .content || move == .table
    }
}
