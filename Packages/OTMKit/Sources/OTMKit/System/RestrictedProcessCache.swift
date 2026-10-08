import Foundation

/// Holds ps's figures by process identity, never by PID alone. Its CPU
/// baseline moves only after a real read, not while a tick repeats a row.
struct RestrictedProcessCache {
    struct Reading: Equatable {
        let cpuSeconds: Double
        let cpuPercent: Double
        let residentBytes: UInt64
        let threads: Int
        let state: ProcessState?
        let time: TimeInterval
    }

    private var readings: [ProcessIdentity: Reading] = [:]

    func reading(for identity: ProcessIdentity) -> Reading? { readings[identity] }

    mutating func update(_ identity: ProcessIdentity, row: PSReader.Row?, threads: Int?, at time: TimeInterval) {
        // A failed ps read leaves the known figure and baseline in place.
        guard let row else { return }
        let previous = readings[identity]
        let interval = previous.map { time - $0.time } ?? 0
        let cpu = previous.map { interval > 0 ? max(row.cpuSeconds - $0.cpuSeconds, 0) / interval * 100 : $0.cpuPercent } ?? 0
        readings[identity] = Reading(cpuSeconds: row.cpuSeconds, cpuPercent: cpu, residentBytes: row.residentBytes,
                                     threads: threads ?? previous?.threads ?? 0, state: row.state, time: time)
    }

    mutating func retain(_ identities: Set<ProcessIdentity>) {
        readings = readings.filter { identities.contains($0.key) }
    }
}
