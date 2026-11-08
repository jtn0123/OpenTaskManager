/// The confirmation every Force Quit asks first (the Processes toolbar's,
/// the inspector's, a row's menu): what it ends, by name, what's lost, and
/// the gentler End Task beside it. Names are fixed as it opens.
public enum ForceQuitPrompt {
    /// Names listed before the rest are counted.
    public static let namesListed = 5

    /// "Force quit Safari?", or "Force quit 3 processes?".
    public static func title(names: [String]) -> String {
        names.count == 1 ? "Force quit \(names[0])?" : "Force quit \(names.count) processes?"
    }

    /// "It stops at once…" for one; for more, their names first, up to
    /// five, then how many more: "Safari, Mail and 4 more stop at once…".
    public static func message(names: [String]) -> String {
        guard names.count > 1 else {
            return "It stops at once, and any unsaved work in it is lost. End Task asks it to quit instead, "
                + "so it can save first."
        }
        return "\(list(names)) stop at once, and any unsaved work in them is lost. End Task asks them to quit "
            + "instead, so they can save first."
    }

    /// "A, B and C"; past five names, "A, B, C, D, E and 3 more".
    static func list(_ names: [String]) -> String {
        let shown = Array(names.prefix(namesListed))
        let more = names.count - shown.count
        if more > 0 { return shown.joined(separator: ", ") + " and \(more) more" }
        guard let last = shown.last, shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }
}
