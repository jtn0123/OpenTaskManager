/// The map keeps useful room before an unfolded reconciliation gets any.
/// Heights come from window and content measurements, never sampler ticks.
public enum StorageResultsLayout {
    public static let mapMinimum: Double = 180
    // The card also holds its breadcrumb, selection strip, caption and padding.
    public static let cardMinimum: Double = mapMinimum + 200
    public static let reconciliationMaximum: Double = 180

    public static func footerHeight(available: Double, summary: Double) -> Double {
        // Page padding and the two gaps between summary, map and footer.
        // A very short page scrolls as a whole too; its panel still has a usable viewport.
        max(120, available - summary - cardMinimum - 32 - 24)
    }

    public static func cardHeight(available: Double, summary: Double, footer: Double) -> Double {
        max(cardMinimum, available - summary - footer - 32 - 24)
    }

    public static func reconciliationHeight(content: Double, available: Double, header: Double) -> Double {
        max(0, min(content, reconciliationMaximum, available - header - 1))
    }
}
