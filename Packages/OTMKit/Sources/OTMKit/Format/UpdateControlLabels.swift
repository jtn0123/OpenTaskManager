/// Live sampling and History playback are independent controls, even while a file is open.
public enum UpdateControlLabels {
    public static func liveTitle(paused: Bool, replaying: Bool, compact: Bool = false) -> String {
        let action = paused ? "Resume" : "Pause"
        return replaying && !compact ? action + " Live" : action
    }

    public static func liveMenuTitle(paused: Bool, replaying: Bool) -> String {
        replaying ? liveTitle(paused: paused, replaying: true) : (paused ? "Resume Updates" : "Pause Updates")
    }

    public static func liveAccessibility(paused: Bool) -> String {
        paused ? "Resume Live" : "Pause Live"
    }

    public static func liveHelp(paused: Bool, replaying: Bool) -> String {
        let action = paused ? "Resume live updates" : "Pause live updates"
        return action + (replaying ? "; History replay continues independently" : "") + " (⇧⌘P)"
    }

    public static func replayTitle(playing: Bool, hasPlayhead: Bool) -> String {
        playing ? "Pause Replay" : hasPlayhead ? "Resume Replay" : "Play Replay"
    }

    public static func replayHelp(playing: Bool) -> String {
        playing ? "Pause replay where it is. Live updates are controlled separately."
            : "Play the timeline back from the pinned moment, else where it paused (or the picked session), "
                + "skipping what wasn't recorded. Live updates are controlled separately."
    }
}
