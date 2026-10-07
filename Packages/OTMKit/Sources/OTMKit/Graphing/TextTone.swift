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
}
