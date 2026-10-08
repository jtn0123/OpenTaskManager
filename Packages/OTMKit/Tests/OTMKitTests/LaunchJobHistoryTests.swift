import Foundation
import Testing
@testable import OTMKit

struct LaunchJobHistoryTests {
    private let key = LaunchHistoryKey(label: "org.example.job", domain: "gui/501")

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func snapshot(_ seconds: Double, pid: Int32? = nil, exit: Int32? = nil, loaded: Bool = true,
                          started: Double? = nil, configuration: LaunchJobConfiguration? = nil) -> LaunchHistorySnapshot {
        let job = loaded ? LaunchJobStatus(label: key.label, pid: pid, lastExit: exit.map(LaunchExitStatus.code)) : nil
        return LaunchHistorySnapshot(key: key, time: date(seconds), job: job, started: started.map(date), configuration: configuration)
    }

    @Test func firstReadIsABaselineNotAStartOrAFailure() {
        let events = LaunchHistoryDerivation.events(from: nil, to: snapshot(1_000, pid: 1, exit: 78))
        #expect(events.map(\.kind) == [.observed])
        #expect(events.first?.words == "First observed running · PID 1 · Last reported: Exited with code 78")
        #expect(LaunchHistoryPattern.verdict(events, coverage: [], at: date(1_000)) == nil)
    }

    @Test func unchangedFailureIsNeverCountedAgain() {
        #expect(LaunchHistoryDerivation.events(from: snapshot(1_000, exit: 78), to: snapshot(1_010, exit: 78)).isEmpty)
    }

    @Test func startExitCrashLoadAndUnloadHaveObservedBounds() {
        let start = LaunchHistoryDerivation.events(from: snapshot(1_000), to: snapshot(1_010, pid: 2))
        #expect(start.map(\.kind) == [.started])
        #expect(start.first?.pid == 2)
        #expect(start.first?.since == date(1_000))
        let crash = LaunchHistoryDerivation.events(from: snapshot(1_010, pid: 2), to: snapshot(1_020, exit: -11))
        #expect(crash.map(\.kind) == [.exited, .crashed])
        #expect(crash.first?.words == "Killed by signal 11 (SIGSEGV)")
        let load = LaunchHistoryDerivation.events(from: snapshot(1_000, loaded: false), to: snapshot(1_010))
        #expect(load.map(\.kind) == [.loaded])
        let unload = LaunchHistoryDerivation.events(from: snapshot(1_010, pid: 2), to: snapshot(1_020, loaded: false))
        #expect(unload.map(\.kind) == [.unloaded])
        #expect(unload.first?.exit == nil, "unloading doesn't establish the exit code")
    }

    @Test func newPIDDoesNotInheritAStaleExit() {
        let events = LaunchHistoryDerivation.events(from: snapshot(1_000, pid: 1, exit: 78), to: snapshot(1_010, pid: 2, exit: 78))
        #expect(events.map(\.kind) == [.exited, .started, .restarted])
        #expect(events.first?.exit == nil)
        #expect(events.first?.words == "Run ended · exit unknown")
    }

    @Test func reusedPIDIsANewRunWhenStartTimesDiffer() {
        let events = LaunchHistoryDerivation.events(from: snapshot(1_000, pid: 1, started: 900),
                                                   to: snapshot(1_010, pid: 1, started: 1_005))
        #expect(events.contains { $0.kind == .restarted })
    }

    @Test func gapsAndOutOfOrderReadsNeverInventTransitions() {
        let events = LaunchHistoryDerivation.events(from: snapshot(1_000, pid: 1), to: snapshot(1_200, pid: 2, exit: 78))
        #expect(events.map(\.kind) == [.observed, .failed])
        #expect(events.first?.since == date(1_000))
        #expect(LaunchHistoryDerivation.events(from: snapshot(1_010), to: snapshot(1_000, pid: 1)).isEmpty)
        var tracker = LaunchHistoryTracker()
        _ = tracker.observe(snapshot(1_010, pid: 1))
        #expect(tracker.observe(snapshot(1_000, pid: 2)).isEmpty)
    }

    @Test func restartThroughIdleCountsOnceAndBecomesRestarting() {
        var tracker = LaunchHistoryTracker()
        _ = tracker.observe(snapshot(1_000, pid: 1))
        for index in 1...3 {
            let time = 1_000 + Double(index * 20)
            _ = tracker.observe(snapshot(time - 10, exit: 1))
            let events = tracker.observe(snapshot(time, pid: Int32(index + 1), exit: 1))
            #expect(events.filter { $0.kind == .restarted }.count == 1)
            #expect(events.contains { $0.kind == .restarting } == (index == 3))
        }
    }

    private func configuration(_ path: String = "/Library/LaunchAgents/job.plist", modified: Double = 1,
                               program: String = "/usr/bin/true", arguments: [String] = []) -> LaunchJobConfiguration {
        let item = LaunchItems.item(plist: Data("""
            <?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>org.example.job</string>
            <key>Program</key><string>\(program)</string></dict></plist>
            """.utf8), path: path, scope: .userAgent, modified: date(modified))
        // Arguments are supplied through a real plist, not a mock of its parser.
        if arguments.isEmpty { return LaunchJobConfiguration(item) }
        let plist: [String: Any] = ["Label": key.label, "Program": program, "ProgramArguments": arguments]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return LaunchJobConfiguration(LaunchItems.item(plist: data, path: path, scope: .userAgent, modified: date(modified)))
    }

    @Test func configurationTracksPathDateProgramAndArguments() {
        let original = snapshot(1_000, configuration: configuration())
        let changes = [configuration("/Library/LaunchAgents/renamed.plist"), configuration(modified: 2),
                       configuration(program: "/usr/bin/false"), configuration(arguments: ["true", "--flag"])]
        for changed in changes {
            let events = LaunchHistoryDerivation.events(from: original, to: snapshot(1_010, configuration: changed))
            #expect(events.map(\.kind) == [.configuration])
            #expect(events.first?.configuration == changed)
        }
        var tracker = LaunchHistoryTracker()
        tracker.seedConfigurations([key: configuration()])
        let events = tracker.observe(snapshot(2_000, configuration: configuration(modified: 2)))
        #expect(events.first { $0.kind == .configuration }?.words.contains("time unknown") == true)
    }

    @Test func verdictUsesFactsAndOnlyKnownMeanings() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let events = (0..<14).map { index in
            LaunchHistoryEvent(key: key, time: date(3_600 + Double(index * 300)), kind: .exited, exit: .code(78))
        }
        let coverage = [LaunchHistoryInterval(start: date(3_000), end: date(10_000))]
        let verdict = LaunchHistoryPattern.verdict(events, coverage: coverage, at: date(10_000), calendar: calendar)
        #expect(verdict?.contains("Observed 14 failures today, every ~5 min, always exited with code 78") == true)
        #expect(verdict?.contains("a setup problem") == true)
        let unknown = events.map { LaunchHistoryEvent(key: key, time: $0.time, kind: .exited, exit: .code(1)) }
        #expect(LaunchHistoryPattern.verdict(unknown, coverage: coverage, at: date(10_000), calendar: calendar)?.contains(":") == false)
        let hole = [LaunchHistoryInterval(start: date(3_000), end: date(4_000)),
                    LaunchHistoryInterval(start: date(4_001), end: date(10_000))]
        #expect(LaunchHistoryPattern.verdict(events, coverage: hole, at: date(10_000), calendar: calendar)?.contains("every") == false)
        #expect(LaunchHistoryPattern.verdict(events, coverage: [], at: date(10_000), calendar: calendar)?.contains("every") == false)
        #expect(LaunchHistoryPattern.verdict(events, coverage: coverage, at: date(100_000), calendar: calendar) == nil)
    }

    @Test func confirmedIdleExitsWithTheSameCodeCountOncePerRun() {
        var tracker = LaunchHistoryTracker()
        _ = tracker.observe(snapshot(1_000, pid: 1))
        var events: [LaunchHistoryEvent] = []
        for index in 1...3 {
            let time = 1_000 + Double(index * 20)
            events += tracker.observe(snapshot(time - 10, exit: 78))
            events += tracker.observe(snapshot(time, pid: Int32(index + 1), exit: 78))
        }
        #expect(events.filter { $0.kind == .exited && $0.exit == .code(78) }.count == 3)
    }

    @Test func unloadingAndGapsResetRestartMemory() {
        var tracker = LaunchHistoryTracker()
        _ = tracker.observe(snapshot(1_000, pid: 1))
        _ = tracker.observe(snapshot(1_010, loaded: false))
        #expect(!tracker.observe(snapshot(1_020, pid: 2)).contains { $0.kind == .restarted || $0.kind == .exited })
        #expect(!tracker.observe(snapshot(2_000, pid: 3)).contains { $0.kind == .restarted })
    }

    @Test func retentionIncludesTheBoundaryAndRestartWindowExcludesFutureEvents() {
        let event = LaunchHistoryEvent(key: key, time: date(1_000), kind: .restarted)
        #expect(event.isRetained(at: date(1_000 + FlightRecorder.retention)))
        #expect(!event.isRetained(at: date(1_001 + FlightRecorder.retention)))
        let later = LaunchHistoryEvent(key: key, time: date(1_010), kind: .restarted)
        let future = LaunchHistoryEvent(key: key, time: date(2_000), kind: .restarted)
        #expect(LaunchHistoryPattern.restartSummary([event, later, future], at: date(1_020)) == "Restarted 2× in 5 min")
    }
}
