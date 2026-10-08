import Foundation

/// A verdict counts reported exits, never a failure left unchanged at many reads.
public enum LaunchHistoryPattern {
    public static func verdict(_ events: [LaunchHistoryEvent], at date: Date, calendar: Calendar = .current) -> String? {
        let start = calendar.startOfDay(for: date)
        let failures = events.filter { $0.kind == .exited && $0.exit?.isFailure == true && $0.time >= start && $0.time <= date }
            .sorted { $0.time < $1.time }
        guard failures.count >= 3 else { return nil }
        var text = "Observed \(failures.count) failures today"
        let intervals = zip(failures, failures.dropFirst()).map { $1.time.timeIntervalSince($0.time) }.sorted()
        let median = intervals[intervals.count / 2]
        // Sparse or uneven observation times don't establish a repeating cadence.
        let hasGap = events.contains { $0.kind == .gap && $0.time > failures[0].time && $0.time <= date }
        if !hasGap, median >= 60, intervals.allSatisfy({ abs($0 - median) <= median * 0.25 }) {
            text += ", every ~\(Int((median / 60).rounded())) min"
        }
        if let exit = failures.first?.exit, failures.allSatisfy({ $0.exit == exit }) {
            text += ", always \(exit.description.prefix(1).lowercased() + exit.description.dropFirst())"
            if case let .code(code) = exit {
                let meaning = code < 0 ? LaunchExitStatus.meaning(ofSignal: -code) : LaunchExitStatus.meaning(ofCode: code)
                if let meaning {
                    // Drop the symbolic sysexits prefix and its examples; the
                    // details' existing notice carries the full explanation.
                    let words = meaning.split(separator: ":", maxSplits: 1).last.map(String.init) ?? meaning
                    let summary = words.split(separator: ",", maxSplits: 1).first.map(String.init) ?? words
                    text += ": \(summary.trimmingCharacters(in: .whitespaces))"
                }
            }
        }
        return text
    }

    public static func restartSummary(_ events: [LaunchHistoryEvent], at date: Date) -> String? {
        let count = events.filter { $0.kind == .restarted && $0.time > date.addingTimeInterval(-300) && $0.time <= date }.count
        return count >= 2 ? "Restarted \(count)× in 5 min" : nil
    }
}
