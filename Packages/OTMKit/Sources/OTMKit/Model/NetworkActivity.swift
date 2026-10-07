import Foundation

/// What one app (or one process) moved over the network between two
/// readings, in bytes per second.
public struct NetworkUsage: Sendable, Hashable {
    public var received: Double
    public var sent: Double
    /// Processes whose traffic is counted here.
    public var processes: Int

    public var total: Double { received + sent }

    public init(received: Double, sent: Double, processes: Int = 1) {
        self.received = received
        self.sent = sent
        self.processes = processes
    }
}

/// Rolls per-process traffic up into the apps responsible for it, the way
/// the grouped process list folds helpers under their app, so Safari's
/// traffic includes its networking and web content processes.
public enum NetworkGrouping {
    /// Every PID in `groups` mapped to the PID of the group it belongs to.
    /// `groups` are the grouped tree's top-level process rows (sections are
    /// looked through), as `AppModel.appGroups` holds them.
    public static func owners(_ groups: [ProcessNode]) -> [Int32: Int32] {
        var owners: [Int32: Int32] = [:]
        func claim(_ node: ProcessNode, for owner: Int32) {
            if let pid = node.process?.pid { owners[pid] = owner }
            node.children.forEach { claim($0, for: owner) }
        }
        func visit(_ node: ProcessNode) {
            if let pid = node.process?.pid {
                claim(node, for: pid)
            } else {
                node.children.forEach(visit)
            }
        }
        groups.forEach(visit)
        return owners
    }

    /// Each owner's traffic. A process outside every group (one that started
    /// since the process list was read, or one it leaves out) stands for itself.
    public static func byApp(_ rates: [ProcessNetworkRate], owners: [Int32: Int32]) -> [Int32: NetworkUsage] {
        var usage: [Int32: NetworkUsage] = [:]
        for rate in rates {
            let owner = owners[rate.pid] ?? rate.pid
            var entry = usage[owner] ?? NetworkUsage(received: 0, sent: 0, processes: 0)
            entry.received += rate.bytesInPerSecond
            entry.sent += rate.bytesOutPerSecond
            entry.processes += 1
            usage[owner] = entry
        }
        return usage
    }

    /// Each process's traffic on its own.
    public static func byProcess(_ rates: [ProcessNetworkRate]) -> [Int32: NetworkUsage] {
        Dictionary(rates.map { ($0.pid, NetworkUsage(received: $0.bytesInPerSecond, sent: $0.bytesOutPerSecond)) },
                   uniquingKeysWith: { first, _ in first })
    }
}

/// A short rolling window of network traffic per key (an app or a process),
/// enough for small graphs.
///
/// Every key's series is as long as the window so far, padded with zeros
/// before it first moved anything, so the series stack cleanly. A key that
/// moved nothing for the whole window is dropped, which keeps the window as
/// small as the set of apps actually using the network.
public struct NetworkActivityHistory<Key: Hashable & Comparable & Sendable>: Sendable {
    /// Readings kept, the oldest dropped first.
    public let capacity: Int
    /// Readings held so far, up to `capacity`.
    public private(set) var length = 0
    /// Receive plus send per reading, oldest first, for every key that moved
    /// something in the window.
    public private(set) var totals: [Key: [Double]] = [:]
    /// The newest reading: every key that moved something in it.
    public private(set) var latest: [Key: NetworkUsage] = [:]

    public init(capacity: Int) {
        precondition(capacity > 0, "History capacity must be positive")
        self.capacity = capacity
    }

    public var isEmpty: Bool { length == 0 }
    /// Whether anything moved at all in the window.
    public var isQuiet: Bool { totals.isEmpty }

    /// Whether anything moved in the newest `readings` readings. A ranking
    /// that keeps its room for a few quiet readings doesn't come and go
    /// with every pause in the traffic.
    public func hasMoved(inLast readings: Int) -> Bool {
        totals.values.contains { $0.suffix(max(readings, 0)).contains { $0 > 0 } }
    }

    public mutating func append(_ usage: [Key: NetworkUsage]) {
        length = min(length + 1, capacity)
        var next: [Key: [Double]] = [:]
        next.reserveCapacity(totals.count + usage.count)
        for key in Set(totals.keys).union(usage.keys) {
            var values = totals[key] ?? []
            values.append(max(usage[key]?.total ?? 0, 0))
            if values.count < length {
                values.insert(contentsOf: repeatElement(0, count: length - values.count), at: 0)
            } else if values.count > length {
                values.removeFirst(values.count - length)
            }
            if values.contains(where: { $0 > 0 }) { next[key] = values }
        }
        totals = next
        latest = usage.filter { $0.value.total > 0 }
    }

    public mutating func removeAll() {
        length = 0
        totals = [:]
        latest = [:]
    }

    /// A key's rates summed over the window, for ranking.
    public func volume(_ key: Key) -> Double {
        totals[key]?.reduce(0, +) ?? 0
    }

    /// The keys to draw as bands of their own (at most `bands`, the busiest
    /// over the whole window) and the keys to list (at most `rows`: whatever
    /// is moving data now, busiest first, then bands that have gone quiet, so
    /// each band keeps its row).
    public func ranking(bands: Int, rows: Int) -> (bands: [Key], rows: [Key]) {
        var volumes: [Key: Double] = [:]
        for key in totals.keys { volumes[key] = volume(key) }
        func busier(_ lhs: Key, _ rhs: Key) -> Bool {
            let left = volumes[lhs] ?? 0, right = volumes[rhs] ?? 0
            return left == right ? lhs < rhs : left > right
        }
        let banded = Array(volumes.keys.sorted(by: busier).prefix(max(bands, 0)))
        let listed = Set(latest.keys).union(banded).sorted { lhs, rhs in
            let left = latest[lhs]?.total ?? 0, right = latest[rhs]?.total ?? 0
            return left == right ? busier(lhs, rhs) : left > right
        }
        return (banded, Array(listed.prefix(max(rows, 0))))
    }

    /// Every key but `keys`, summed per reading: the "everything else" band.
    public func remainder(excluding keys: [Key]) -> [Double] {
        let excluded = Set(keys)
        var sum = [Double](repeating: 0, count: length)
        for (key, values) in totals where !excluded.contains(key) {
            for (index, value) in values.enumerated() { sum[index] += value }
        }
        return sum
    }
}
