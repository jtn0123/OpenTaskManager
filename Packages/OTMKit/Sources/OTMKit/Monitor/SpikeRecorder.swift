import Foundation

/// Keeps the last few minutes of updates in detail, each with its busiest
/// processes by CPU, memory and disk, and watches them with `SpikeTriggers`.
/// When something triggers it carries on for `after` seconds, then hands off
/// one `SpikeCapture`: the updates from `before` seconds ahead of the trigger
/// to the end, with any other kind that crossed meanwhile.
///
/// The ring is allocated once, `capacity` updates of fixed-size samples and
/// a flat buffer of `processesPerSlot` processes each, so feeding it an
/// update reuses a slot: one pass over the process list with a few
/// comparisons a process, through pointers, and no allocation unless a
/// process makes a top list (its name is retained) or a capture is handed off.
public struct SpikeRecorder: Sendable {
    public static let topCPUKept = 5
    public static let topMemoryKept = 5
    public static let topDiskKept = 3
    /// The processes an incident names: more than a top list holds, so
    /// several workers of one name taking turns in it are all counted.
    public static let contributorsKept = 8
    static let processesPerSlot = topCPUKept + topMemoryKept + topDiskKept

    /// One update in the ring, and how much of its slot of `processes` each top list fills.
    private struct Slot {
        var sample: SpikeSample
        var cpuCount = 0
        var memoryCount = 0
        var diskCount = 0
    }

    /// A capture under way: its triggers so far, when it ends, and when the
    /// first trigger's condition ended, once it has.
    private struct Pending {
        var triggers: [SpikeTrigger]
        var end: Date
        var cleared: Date?
    }

    /// A debug build's forced capture, taken on the next update.
    private struct Forced {
        let kind: SpikeKind
        let after: TimeInterval
    }

    /// Updates the ring holds: enough for `before` plus `after` at the fastest update speed.
    public let capacity: Int
    /// Seconds of updates kept from before a capture's first trigger.
    public let before: TimeInterval
    /// Seconds a capture carries on after its first trigger.
    public let after: TimeInterval
    public private(set) var triggers: SpikeTriggers
    private var slots: [Slot]
    private var processes: [SpikeProcess]
    /// The slot the next update goes in.
    private var next = 0
    /// Updates in the ring.
    public private(set) var count = 0
    private var pending: Pending?
    private var forced: Forced?
    private var logicalCores = 1
    private var last: Date?

    public init(thresholds: SpikeThresholds = SpikeThresholds(), before: TimeInterval = 120, after: TimeInterval = 60,
                capacity: Int = 400) {
        self.capacity = max(capacity, 1)
        self.before = max(before, 0)
        self.after = max(after, 0)
        triggers = SpikeTriggers(thresholds: thresholds)
        slots = Array(repeating: Slot(sample: SpikeSample(time: .distantPast, interval: 0)), count: self.capacity)
        processes = Array(repeating: .empty, count: self.capacity * Self.processesPerSlot)
    }

    /// The kind a capture under way is about, nil when none is.
    public var capturing: SpikeKind? { pending?.triggers.first?.kind }

    /// Takes one update's figures and process list. Returns a capture once
    /// one is complete: `after` seconds past its first trigger, or at the
    /// first update after a pause or sleep past its end. A capture is never
    /// made of updates from either side of the clock going backwards.
    public mutating func add(_ sample: SpikeSample, processes list: [ProcessSample], logicalCores: Int) -> SpikeCapture? {
        self.logicalCores = max(logicalCores, 1)
        var handed: SpikeCapture?
        if let last, sample.time < last {
            handed = finish()
            count = 0
        } else if let pending, sample.time > pending.end {
            handed = finish()
        }
        last = sample.time
        store(sample, processes: list)
        var fired = triggers.update(sample)
        if let forced {
            self.forced = nil
            fired.insert(triggers.force(forced.kind, on: sample), at: 0)
            if pending == nil { pending = Pending(triggers: [], end: sample.time.addingTimeInterval(forced.after)) }
        }
        if var capture = pending {
            for trigger in fired where !capture.triggers.contains(where: { $0.kind == trigger.kind }) {
                capture.triggers.append(trigger)
            }
            if capture.cleared == nil, let primary = capture.triggers.first, !triggers.isActive(primary.kind) {
                capture.cleared = sample.time.addingTimeInterval(-sample.interval)
            }
            pending = capture
            if sample.time >= capture.end.addingTimeInterval(-0.001) { handed = finish() ?? handed }
        } else if let first = fired.first {
            pending = Pending(triggers: fired, end: first.time.addingTimeInterval(after))
        }
        return handed
    }

    /// Triggers a capture of `kind` on the next update, whatever its
    /// figures, that ends `after` seconds later: a debug build's way to test
    /// captures. Joins a capture already under way instead.
    public mutating func force(_ kind: SpikeKind, after: TimeInterval) {
        forced = Forced(kind: kind, after: max(after, 0))
    }

    /// Forgets every update and any capture under way, and the triggers'
    /// state: for when captures are turned back on.
    public mutating func reset() {
        next = 0
        count = 0
        pending = nil
        forced = nil
        last = nil
        triggers = SpikeTriggers(thresholds: triggers.thresholds)
    }

    // MARK: - Ring

    private mutating func store(_ sample: SpikeSample, processes list: [ProcessSample]) {
        let slot = next
        next = next + 1 == capacity ? 0 : next + 1
        if count < capacity { count += 1 }
        var cpuCount = 0
        var memoryCount = 0
        var diskCount = 0
        let offset = slot * Self.processesPerSlot
        processes.withUnsafeMutableBufferPointer { buffer in
            list.withUnsafeBufferPointer { input in
                guard let out = buffer.baseAddress, let first = input.baseAddress else { return }
                let cpu = out + offset
                let memory = cpu + Self.topCPUKept
                let disk = memory + Self.topMemoryKept
                var index = 0
                while index < input.count {
                    let process = first + index
                    let load = process.pointee.cpuPercent
                    if load > 0, cpuCount < Self.topCPUKept || load > cpu[cpuCount - 1].value {
                        Self.insert(process, value: load, into: cpu, count: &cpuCount, kept: Self.topCPUKept)
                    }
                    let footprint = Double(process.pointee.memory)
                    if footprint > 0, memoryCount < Self.topMemoryKept || footprint > memory[memoryCount - 1].value {
                        Self.insert(process, value: footprint, into: memory, count: &memoryCount, kept: Self.topMemoryKept)
                    }
                    let bytes = process.pointee.diskReadRate + process.pointee.diskWriteRate
                    if bytes > 0, diskCount < Self.topDiskKept || bytes > disk[diskCount - 1].value {
                        Self.insert(process, value: bytes, into: disk, count: &diskCount, kept: Self.topDiskKept)
                    }
                    index += 1
                }
            }
        }
        slots[slot] = Slot(sample: sample, cpuCount: cpuCount, memoryCount: memoryCount, diskCount: diskCount)
    }

    /// Puts `process` into a top list, highest first, dropping its last
    /// entry when full. A tie goes after what's there.
    private static func insert(_ process: UnsafePointer<ProcessSample>, value: Double, into list: UnsafeMutablePointer<SpikeProcess>,
                               count: inout Int, kept: Int) {
        var position = count < kept ? count : kept - 1
        while position > 0, list[position - 1].value < value {
            list[position] = list[position - 1]
            position -= 1
        }
        list[position] = SpikeProcess(name: process.pointee.name, pid: process.pointee.pid, startTime: process.pointee.startTime,
                                      value: value)
        if count < kept { count += 1 }
    }

    /// The updates in the ring ending after `from` and by `to`, oldest first.
    private func moments(from: Date, to: Date) -> [SpikeMoment] {
        var moments: [SpikeMoment] = []
        moments.reserveCapacity(count)
        var offset = 0
        let oldest = (next - count + capacity) % capacity
        while offset < count {
            let index = (oldest + offset) % capacity
            let slot = slots[index]
            if slot.sample.time > from, slot.sample.time <= to {
                let start = index * Self.processesPerSlot
                let memory = start + Self.topCPUKept
                let disk = memory + Self.topMemoryKept
                moments.append(SpikeMoment(sample: slot.sample, topCPU: Array(processes[start..<start + slot.cpuCount]),
                                           topMemory: Array(processes[memory..<memory + slot.memoryCount]),
                                           topDisk: Array(processes[disk..<disk + slot.diskCount])))
            }
            offset += 1
        }
        return moments
    }

    /// Hands off the capture under way, if any, from what the ring holds.
    private mutating func finish() -> SpikeCapture? {
        guard let capture = pending, let first = capture.triggers.first else {
            pending = nil
            return nil
        }
        pending = nil
        let found = moments(from: first.time.addingTimeInterval(-before), to: capture.end)
        guard !found.isEmpty else { return nil }
        return SpikeCapture(triggers: capture.triggers, moments: found, cleared: capture.cleared, logicalCores: logicalCores)
    }
}
