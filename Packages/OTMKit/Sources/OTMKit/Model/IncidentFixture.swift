import Foundation

/// Made-up evidence is returned as values only, without opening a recorder or writing a database.
public enum IncidentFixture {
    public static func timeline(_ window: IncidentWindow) -> IncidentTimeline {
        let time = window.midpoint
        let identity = ProcessIdentity(pid: 412, startTime: window.start)
        let replacement = ProcessIdentity(pid: 412, startTime: time.addingTimeInterval(1))
        let coverage = IncidentCoverage(window: window, spans: [
            .init(start: window.start, end: time.addingTimeInterval(-15)),
            .init(start: time.addingTimeInterval(15), end: window.end),
        ])
        let full = IncidentCoverage(window: window, spans: [.init(start: window.start, end: window.end)])
        let job = LaunchHistoryKey(label: "com.example.agent", domain: "gui/501")
        let lanes = [
            IncidentLane(kind: .resources, rows: [
                .init(id: "cpu", time: time.addingTimeInterval(3), title: "CPU 85% (was 12%)", kind: "cpuRose"),
                .init(id: "busy", time: time.addingTimeInterval(3), title: "Example Agent", detail: "640% of one core", kind: "busiest"),
                .init(id: "mem", time: time, title: "Memory 74% (was 52%) · pressure 72% (was 40%)"),
                .init(id: "disk", time: time, title: "Disk write 42 MB/s (was 1 MB/s) · network out 8 MB/s (was 0.4 MB/s)"),
            ], coverage: full),
            IncidentLane(kind: .processes, rows: [
                .init(id: "end", time: time, title: "Example Agent ended", detail: "launchd reported exit code 1",
                      process: identity, lifetime: 1, kind: "ended"),
                .init(id: "start", time: time.addingTimeInterval(1), title: "Example Agent started · PID reused",
                      process: replacement, lifetime: 2, kind: "started"),
            ], coverage: coverage),
            IncidentLane(kind: .jobs, rows: [
                .init(id: "restart1", time: time.addingTimeInterval(3), title: "com.example.agent restarted",
                      process: replacement, lifetime: 2, job: job, kind: "restarted"),
                .init(id: "restart2", time: time.addingTimeInterval(20), title: "com.example.agent restarted", job: job, kind: "restarted"),
            ], coverage: coverage, domains: [job.domain: coverage, "system": .init(window: window, spans: [])]),
            IncidentLane(kind: .sockets, rows: [
                .init(id: "old", time: time.addingTimeInterval(-20), title: "Example Agent · socket opened",
                      detail: "127.0.0.1:8080 → 192.0.2.147:443", process: identity, lifetime: 1, socket: "fixture-old",
                      port: 8080, transport: "tcp", remoteAddress: "192.0.2.147", kind: "opened"),
                .init(id: "new", time: time.addingTimeInterval(4), title: "Example Agent · new listener on port 8080",
                      process: replacement, lifetime: 2, socket: "fixture-new", port: 8080, transport: "tcp", kind: "listener"),
            ], coverage: coverage, cut: true, note: "Made-up cut lane; further evidence may exist."),
            IncidentLane(kind: .events, rows: [
                .init(id: "wake", time: time.addingTimeInterval(-40), title: "Mac woke"),
                .init(id: "net", time: time.addingTimeInterval(5), title: "Network changed · Wi-Fi"),
                .init(id: "spike", time: time.addingTimeInterval(8), title: "CPU spike observed"),
            ], coverage: full),
        ]
        return IncidentTimeline(window: window, lanes: lanes, fixture: true)
    }
}
