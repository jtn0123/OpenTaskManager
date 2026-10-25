import Foundation

/// A table column sized by what it holds, so a column of short values that
/// repeat down the table ("Universal", "Apple") stops where they do, and one
/// whose values say what a row is ("Your LaunchAgents folder") isn't cut
/// short while another has room to spare. The widths are the app's, measured
/// in the table's fonts once per read of the rows; this is the rule.
public enum ContentColumnWidth {
    /// Room a cell needs beyond its text's measured width, so rounding never
    /// cuts the last letter.
    public static let cellSlack = 4.0

    /// The width the column's widest value and its title need: never under
    /// `floor`, the column's narrowest, nor over `cap`, past which a value is
    /// cut short and its tooltip has the rest. An empty column (nothing read
    /// yet) still fits its title.
    public static func fitting(content: Double, header: Double, floor: Double, cap: Double? = nil) -> Double {
        let wanted = Swift.max(content > 0 ? content + cellSlack : 0, header, floor)
        guard let cap else { return wanted }
        return Swift.min(wanted, Swift.max(cap, floor))
    }
}
