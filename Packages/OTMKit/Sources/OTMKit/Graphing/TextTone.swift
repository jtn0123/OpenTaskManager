import Foundation

/// How strongly secondary and tertiary text is drawn: the opacity of black
/// ink in light mode and of white ink in dark mode.
///
/// The system's secondary label colour (black at 50%, white at 55%) falls
/// under 4:1 on the app's tinted cards, and its tertiary (about 25%) under
/// 2:1, so labels, captions and metadata washed out. These tones keep
/// secondary text at WCAG AA (4.5:1) on every card tint in both appearances,
/// and tertiary text, kept for placeholders such as "—", at the 3:1 asked of
/// large text and symbols. Both stay well under the primary label's 85%, so
/// the hierarchy still reads.
public enum TextTone {
    public enum Level: Sendable, CaseIterable {
        case secondary
        case tertiary
    }

    /// The opacity of the ink for `level`.
    public static func opacity(_ level: Level, dark: Bool) -> Double {
        switch level {
        case .secondary: dark ? 0.66 : 0.62
        case .tertiary: dark ? 0.46 : 0.45
        }
    }

    /// The colour text at `level` comes out as over `background`.
    public static func color(_ level: Level, dark: Bool, over background: ColorContrast.RGB) -> ColorContrast.RGB {
        let ink = dark ? ColorContrast.RGB.white : ColorContrast.RGB.black
        return ColorContrast.composite(ink, opacity: opacity(level, dark: dark), over: background)
    }

    /// Contrast of text at `level` against `background`.
    public static func contrast(_ level: Level, dark: Bool, on background: ColorContrast.RGB) -> Double {
        ColorContrast.ratio(color(level, dark: dark, over: background), background)
    }

    // MARK: Search highlights

    /// The marker yellow behind the words a search found. Text over it is
    /// drawn in the primary label's ink (`primaryOpacity`), and bold, so a
    /// find doesn't rest on the colour alone.
    public static let highlight = ColorContrast.RGB(red: 1, green: 0.8, blue: 0)
    /// The primary label's ink: black or white at 85%.
    public static let primaryOpacity = 0.85

    /// How strongly the highlight is laid over a card: lighter in dark mode,
    /// where a stronger yellow would take white ink under 4.5:1.
    public static func highlightOpacity(dark: Bool) -> Double {
        dark ? 0.2 : 0.45
    }

    /// Contrast of primary text over the highlight, laid over `card`.
    public static func highlightContrast(dark: Bool, on card: ColorContrast.RGB) -> Double {
        let wash = ColorContrast.composite(highlight, opacity: highlightOpacity(dark: dark), over: card)
        let ink = ColorContrast.composite(dark ? .white : .black, opacity: primaryOpacity, over: wash)
        return ColorContrast.ratio(ink, wash)
    }
}
