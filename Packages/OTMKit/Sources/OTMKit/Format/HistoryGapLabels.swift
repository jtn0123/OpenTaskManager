/// Records alone cannot tell why a gap happened, so the rail names the possible causes.
public enum HistoryGapLabels {
    public static func help(span: String, duration: String) -> String {
        "Not recorded · \(span) · \(duration). The app wasn't running, the Mac slept, or live updates were paused. "
            + "Every figure leaves this gap out."
    }
}
