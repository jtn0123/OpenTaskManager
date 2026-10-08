import Foundation

public enum ListenerReviewWords {
    public static func changeCount(_ count: Int) -> String {
        "\(count) listener \(count == 1 ? "change" : "changes")"
    }

    public static func baseline(_ review: ListenerReview?) -> String {
        guard let baseline = review?.baseline else { return "Baseline has not been set yet." }
        let action = baseline.setAt == baseline.reviewedAt ? "set" : "reviewed"
        return "Baseline \(action) at \(baseline.reviewedAt.formatted(date: .omitted, time: .shortened)) "
            + "with \(baseline.listeners.count) listeners"
    }
}
