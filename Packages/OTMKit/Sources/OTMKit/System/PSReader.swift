import Foundation

/// Reads the setuid `/bin/ps`, the only unprivileged way to see CPU time and
/// resident size for root and other users' processes.
enum PSReader {
    struct Row: Equatable {
        let cpuSeconds: Double
        let residentBytes: UInt64
        let state: ProcessState?
    }

    static func read() -> [Int32: Row] {
        guard let output = run(["-axo", "pid=,state=,cputime=,rss="]) else { return [:] }
        return parse(output)
    }

    static func readThreadCounts() -> [Int32: Int] {
        guard let output = run(["-axM"]) else { return [:] }
        return parseThreadCounts(output)
    }

    static func parse(_ output: String) -> [Int32: Row] {
        var rows: [Int32: Row] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let pid = Int32(fields[0]),
                  let cpu = parseCPUTime(fields[2]), let rss = UInt64(fields[3]) else { continue }
            rows[pid] = Row(cpuSeconds: cpu, residentBytes: rss * 1024, state: state(fromCode: fields[1]))
        }
        return rows
    }

    /// `ps -M` prints the owning user on a process's first thread line and
    /// leaves that column blank on the rest, so blank lines are extra threads.
    static func parseThreadCounts(_ output: String) -> [Int32: Int] {
        var counts: [Int32: Int] = [:]
        var current: Int32?
        for line in output.split(separator: "\n").dropFirst() {
            if line.first?.isWhitespace == false {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                current = fields.count > 1 ? Int32(fields[1]) : nil
                if let current { counts[current] = 1 }
            } else if let current {
                counts[current, default: 0] += 1
            }
        }
        return counts
    }

    /// Parses `[[dd-]hh:]mm:ss.cc`.
    static func parseCPUTime<S: StringProtocol>(_ text: S) -> Double? {
        var days = 0.0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            guard let value = Double(clock[..<dash]) else { return nil }
            days = value
            clock = clock[clock.index(after: dash)...]
        }
        var seconds = 0.0
        for part in clock.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    static func state<S: StringProtocol>(fromCode code: S) -> ProcessState? {
        switch code.first {
        case "R": .running
        case "S", "U": .sleeping
        case "I": .idle
        case "T": .stopped
        case "Z": .zombie
        default: nil
        }
    }

    private static func run(_ arguments: [String]) -> String? {
        // ps exits non-zero when some processes vanished mid-listing; the rest still counts.
        CommandRunner.execute("/bin/ps", arguments, capture: .output, timeout: 5)?.text
    }
}
