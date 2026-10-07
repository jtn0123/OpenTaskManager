import Darwin
import Foundation

/// The bytes a process has received and sent over its sockets, as `nettop`
/// counts them. The counts only grow while the process runs.
public struct ProcessTraffic: Sendable, Hashable {
    public let pid: Int32
    /// The process's name, which `nettop` cuts to 15 characters; `read()`
    /// fills in the whole name where it can.
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: Int32, name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// How fast a process received and sent between two readings.
public struct ProcessNetworkRate: Sendable, Codable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public var total: Double { bytesInPerSecond + bytesOutPerSecond }

    public init(pid: Int32, name: String, bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.pid = pid
        self.name = name
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Per-process network traffic from `/usr/bin/nettop`, which reads every
/// process's sockets, root's included, without special rights. One reading
/// costs about 20 ms of CPU, so callers sample it every few seconds, not per tick.
public enum ProcessNetwork {
    /// One reading of every process with sockets, keyed by PID. Nil when nettop can't run.
    /// With `excludingLoopback`, only sockets on real interfaces count, so a
    /// local server talking to a browser on the same Mac isn't network traffic.
    public static func read(excludingLoopback: Bool = false) -> [Int32: ProcessTraffic]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // Per process (-P), one CSV sample (-L 1), raw numbers (-x), two columns (-J);
        // `-t external` keeps every interface but loopback.
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"] + (excludingLoopback ? ["-t", "external"] : [])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self)).mapValues { traffic in
            // Only when it starts with nettop's name, in case the PID was reused in between.
            guard let full = fullName(traffic.pid), full.count > traffic.name.count, full.hasPrefix(traffic.name) else { return traffic }
            return ProcessTraffic(pid: traffic.pid, name: full, bytesIn: traffic.bytesIn, bytesOut: traffic.bytesOut)
        }
    }

    private static func fullName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// Parses `nettop -P -L 1 -x -J bytes_in,bytes_out`: a header row, then
    /// `name.pid,bytes_in,bytes_out,` per process. Names may hold dots and
    /// commas, so fields are read from the right.
    public static func parse(_ output: String) -> [Int32: ProcessTraffic] {
        var traffic: [Int32: ProcessTraffic] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count >= 3,
                  let bytesOut = UInt64(fields[fields.count - 1]),
                  let bytesIn = UInt64(fields[fields.count - 2]) else { continue }
            let identifier = fields[..<(fields.count - 2)].joined(separator: ",")
            guard let dot = identifier.lastIndex(of: "."),
                  let pid = Int32(identifier[identifier.index(after: dot)...]) else { continue }
            traffic[pid] = ProcessTraffic(pid: pid, name: String(identifier[..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
        return traffic
    }

    /// Each process's rates between two readings, busiest first. Processes
    /// that moved nothing, or that are new (or whose PID was reused), are left out.
    public static func rates(
        from old: [Int32: ProcessTraffic], to new: [Int32: ProcessTraffic], interval: TimeInterval
    ) -> [ProcessNetworkRate] {
        guard interval > 0 else { return [] }
        return new.values.compactMap { current -> ProcessNetworkRate? in
            guard let previous = old[current.pid], previous.name == current.name,
                  current.bytesIn >= previous.bytesIn, current.bytesOut >= previous.bytesOut else { return nil }
            let rate = ProcessNetworkRate(
                pid: current.pid, name: current.name,
                bytesInPerSecond: Double(current.bytesIn - previous.bytesIn) / interval,
                bytesOutPerSecond: Double(current.bytesOut - previous.bytesOut) / interval
            )
            return rate.total > 0 ? rate : nil
        }
        .sorted { $0.total == $1.total ? $0.pid < $1.pid : $0.total > $1.total }
    }
}
