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

    // The parsers walk ps's output byte by byte through a pointer: it's about
    // 650 lines every tick (and a line per thread every few seconds), and
    // splitting it into Substrings cost more than running ps.

    static func parse(_ output: String) -> [Int32: Row] {
        var rows: [Int32: Row] = [:]
        rows.reserveCapacity(1024)
        withBytes(output) { text in
            while var line = text.line() {
                guard let pid = line.field()?.processID(), let code = line.field()?.first,
                      let cpu = line.field()?.cpuTime(), let rss = line.field()?.integer() else { continue }
                rows[pid] = Row(cpuSeconds: cpu, residentBytes: rss * 1024, state: state(fromByte: code))
            }
        }
        return rows
    }

    /// `ps -M` prints the owning user on a process's first thread line and
    /// leaves that column blank on the rest, so blank lines are extra threads.
    static func parseThreadCounts(_ output: String) -> [Int32: Int] {
        var counts: [Int32: Int] = [:]
        withBytes(output) { text in
            _ = text.line()
            var current: Int32?
            while var line = text.line() {
                if line.first.map(Bytes.isBlank) == false {
                    _ = line.field()
                    current = line.field()?.processID()
                    if let current { counts[current] = 1 }
                } else if let current {
                    counts[current, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Parses `[[dd-]hh:]mm:ss.cc`.
    static func parseCPUTime<S: StringProtocol>(_ text: S) -> Double? {
        var result: Double?
        withBytes(String(text)) { result = $0.cpuTime() }
        return result
    }

    static func state<S: StringProtocol>(fromCode code: S) -> ProcessState? {
        code.utf8.first.flatMap(state(fromByte:))
    }

    private static func state(fromByte code: UInt8) -> ProcessState? {
        switch code {
        case UInt8(ascii: "R"): .running
        case UInt8(ascii: "S"), UInt8(ascii: "U"): .sleeping
        case UInt8(ascii: "I"): .idle
        case UInt8(ascii: "T"): .stopped
        case UInt8(ascii: "Z"): .zombie
        default: nil
        }
    }

    private static func withBytes(_ text: String, _ body: (inout Bytes) -> Void) {
        var text = text
        text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return }
            var bytes = Bytes(base: base, start: 0, end: buffer.count)
            body(&bytes)
        }
    }

    /// A run of ps's output, read from the front. It indexes a raw pointer
    /// rather than a buffer or a Substring so debug builds don't go through
    /// the standard library's unspecialized generics for every byte.
    private struct Bytes {
        let base: UnsafePointer<UInt8>
        var start: Int
        let end: Int

        static func isBlank(_ byte: UInt8) -> Bool {
            byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= 0x30 && byte <= 0x39
        }

        var first: UInt8? { start < end ? base[start] : nil }

        /// The next line that isn't empty.
        mutating func line() -> Bytes? {
            while start < end, base[start] == 0x0A { start += 1 }
            return upTo(0x0A)
        }

        /// The next space-separated field.
        mutating func field() -> Bytes? {
            while start < end, base[start] == 0x20 { start += 1 }
            return upTo(0x20)
        }

        /// The bytes before the next `separator` (or the end), stepping past
        /// it; nil once nothing is left.
        mutating func upTo(_ separator: UInt8) -> Bytes? {
            guard start < end else { return nil }
            var stop = start
            while stop < end, base[stop] != separator { stop += 1 }
            defer { start = Swift.min(stop + 1, end) }
            return Bytes(base: base, start: start, end: stop)
        }

        /// Digits only, as ps prints PIDs and sizes.
        func integer() -> UInt64? {
            guard start < end else { return nil }
            var value: UInt64 = 0
            var index = start
            while index < end {
                guard Self.isDigit(base[index]) else { return nil }
                let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                value = shifted + UInt64(base[index] &- 0x30)
                index += 1
            }
            return value
        }

        func processID() -> Int32? {
            integer().flatMap { $0 <= UInt64(Int32.max) ? Int32($0) : nil }
        }

        func cpuTime() -> Double? {
            var days = 0.0
            var clock = self
            var dash = start
            while dash < end, base[dash] != 0x2D { dash += 1 } // "-"
            if dash < end {
                guard let value = Bytes(base: base, start: start, end: dash).decimal() else { return nil }
                days = value
                clock.start = dash + 1
            }
            var seconds = 0.0
            while let part = clock.upTo(0x3A) { // ":"
                guard part.start < part.end else { continue }
                guard let value = part.decimal() else { return nil }
                seconds = seconds * 60 + value
            }
            return days * 86_400 + seconds
        }

        /// A plain decimal such as "56.48", rounded as `Double("56.48")` is:
        /// the digits make an exact whole number, and one division by a power
        /// of ten rounds it correctly. Anything else goes to `Double`'s parser.
        func decimal() -> Double? {
            var digits: UInt64 = 0
            var count = 0
            var places = -1
            var index = start
            while index < end {
                let byte = base[index]
                if byte == 0x2E, places < 0 { // "."
                    places = 0
                } else if Self.isDigit(byte), count < 15 {
                    digits = digits * 10 + UInt64(byte &- 0x30)
                    count += 1
                    if places >= 0 { places += 1 }
                } else {
                    return Double(String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self))
                }
                index += 1
            }
            guard count > 0 else { return nil }
            var scale = 1.0
            while places > 0 {
                scale *= 10
                places -= 1
            }
            return Double(digits) / scale
        }
    }

    private static func run(_ arguments: [String]) -> String? {
        // ps exits non-zero when some processes vanished mid-listing; the rest still counts.
        CommandRunner.execute("/bin/ps", arguments, capture: .output, timeout: 5)?.text
    }
}
