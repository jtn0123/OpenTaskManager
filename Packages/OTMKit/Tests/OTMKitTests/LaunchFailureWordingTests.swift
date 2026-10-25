import Foundation
@testable import OTMKit
import Testing

struct LaunchFailureWordingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = LaunchHistoryKey(label: "example.daemon", domain: "system")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var failed: LaunchItemStatus {
        LaunchItemStatus(execution: .failed(code: 1), registration: .init(isLoaded: true, isDisabled: false), needsAttention: true)
    }

    @Test func headerDatesTheLastExitWithoutChangingTheProblemsState() {
        let seen = now.addingTimeInterval(-60)
        let words = failed.headerSummary(firstSeen: seen, at: now, calendar: calendar) { _, includesDate in
            includesDate ? "Oct 5, 10:21 AM" : "10:21 AM"
        }
        #expect(words == "Not running · last exit code 1 at 10:21 AM")
        #expect(failed.title == "Failed")
        #expect(failed.compactDetail == "exit 1")
        #expect(failed.needsAttention)
        let earlier = failed.headerSummary(firstSeen: now.addingTimeInterval(-86_400), at: now, calendar: calendar) { _, includesDate in
            includesDate ? "Oct 5, 10:21 AM" : "10:21 AM"
        }
        #expect(earlier == "Not running · last exit code 1 at Oct 5, 10:21 AM")
    }

    @Test func unknownTimeIsExplicitAndATooltipExplainsFirstSeen() {
        #expect(failed.headerSummary(firstSeen: nil) == "Not running · last exit code 1 · time not known")
        #expect(failed.observationExplanation(firstSeen: nil).contains("First seen: time not known."))
        let tooltip = failed.observationExplanation(firstSeen: now, at: now, calendar: calendar) { _, _ in "10:21 AM" }
        #expect(tooltip.contains("First seen: 10:21 AM."))
        #expect(tooltip.contains("not the exact exit time"))
    }

    @Test func onlyTheMatchingRetainedFailureSuppliesATime() {
        func state(key: LaunchHistoryKey, pid: Int32? = nil, exit: LaunchExitStatus? = .code(1)) -> LaunchHistoryState {
            LaunchHistoryState(LaunchHistorySnapshot(key: key, time: now,
                                                     job: LaunchJobStatus(label: key.label, pid: pid, lastExit: exit)))
        }
        #expect(failed.failureFirstSeen(in: state(key: key), key: key) == now)
        #expect(failed.failureFirstSeen(in: nil, key: key) == nil)
        #expect(failed.failureFirstSeen(in: state(key: key, pid: 3), key: key) == nil)
        #expect(failed.failureFirstSeen(in: state(key: key, exit: .code(2)), key: key) == nil)
        #expect(failed.failureFirstSeen(in: state(key: .init(label: key.label, domain: "gui/501")), key: key) == nil)
        let unloaded = LaunchHistoryState(LaunchHistorySnapshot(key: key, time: now, job: nil))
        #expect(failed.failureFirstSeen(in: unloaded, key: key) == nil)
    }

    @Test func runningAndRestartingKeepTheirExistingWords() {
        for execution in [LaunchItemStatus.Execution.running(pid: 501), .restarting(count: 3), .crashed(signal: 11), .notRunning] {
            let status = LaunchItemStatus(execution: execution, registration: .init(isLoaded: true, isDisabled: false), needsAttention: true)
            #expect(status.headerSummary(firstSeen: now) == status.summary)
            #expect(status.observationExplanation(firstSeen: now) == status.explanation)
            #expect(status.failureFirstSeen(in: LaunchHistoryState(LaunchHistorySnapshot(key: key, time: now,
                job: LaunchJobStatus(label: key.label, pid: nil, lastExit: .code(1)))), key: key) == nil)
        }
    }
}
