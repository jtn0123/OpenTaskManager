import Foundation

/// Short replay labels keep the event and its time separate, so neither
/// has to lose words to make room for the other.
public enum HistoryReplayLabels {
    public static let processNotice = "This recording doesn't keep process histories"
    public static let searchLive = "Search Live History"
    public static let readOnly = "Read-only"

    public static func eventTitle(_ event: HistoryEvent) -> String {
        let name = event.count > 1 ? "\(event.count) × \(event.name)" : event.name
        return switch event.kind {
        case .appLaunched: "\(name) launched"
        case .appQuit: "\(name) quit"
        case .processStarted: "\(name) started"
        case .processExited: "\(name) exited"
        case .networkChanged: event.name.isEmpty ? "Network disconnected" : "Network: \(event.name)"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke"
        case .spike: "\(name) spike captured"
        }
    }

    public static func eventOffset(_ event: HistoryEvent, at time: Date, bucket: TimeInterval) -> String {
        let seconds = event.time.timeIntervalSince(time)
        let text: String
        if seconds <= 0, seconds > -bucket {
            text = "during these \(Format.timeSpan(bucket))"
        } else {
            text = "\(Format.timeSpan(abs(seconds).rounded())) \(seconds < 0 ? "before" : "after")"
        }
        return event.isApproximate ? "about " + text : text
    }

    public static func triggerTime(_ trigger: SpikeTrigger) -> String {
        "\(trigger.kind.shortLabel) crossed at \(trigger.time.formatted(date: .omitted, time: .standard))"
    }

    public static func recordCount(_ count: Int, seconds: TimeInterval) -> String {
        let length = seconds == FlightRecorder.span ? "" : " of \(Format.timeSpan(seconds))"
        return "\(count) \(count == 1 ? "record" : "records")\(length)"
    }

    public static func machine(_ summary: String, notReported: [String]) -> String {
        "Recorded on \(summary)"
            + (notReported.isEmpty ? "" : " · \(ListFormatter.localizedString(byJoining: notReported)) not reported")
    }
}
