import Foundation

/// One update's whole-system figures as the spike recorder keeps them: a
/// fixed-size value, so a ring of them never allocates as it turns.
public struct SpikeSample: Sendable, Equatable {
    /// The end of the update's interval.
    public var time: Date
    /// Seconds the update covers.
    public var interval: TimeInterval
    public var cpu = 0.0
    public var memory = 0.0
    public var memoryPressure = 0.0
    public var pressure = MemoryPressure.normal
    public var thermal = ThermalState.nominal
    public var swapUsed = 0.0
    public var gpu: Double?
    public var systemWatts: Double?
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var diskRead = 0.0
    public var diskWrite = 0.0
    public var networkIn = 0.0
    public var networkOut = 0.0
    public var chipCelsius: Double?

    public init(time: Date, interval: TimeInterval) {
        self.time = time
        self.interval = interval
    }

    /// The figures the flight recorder takes from the same update (its
    /// hardware series and core loads aren't kept), with the pressure levels
    /// it doesn't record.
    public init(_ values: HistoryValues, pressure: MemoryPressure, thermal: ThermalState, interval: TimeInterval, at time: Date) {
        self.time = time
        self.interval = interval
        cpu = values.cpu
        memory = values.memory
        memoryPressure = values.memoryPressure
        self.pressure = pressure
        self.thermal = thermal
        swapUsed = values.swapUsed
        gpu = values.gpu
        systemWatts = values.systemWatts
        cpuWatts = values.cpuWatts
        gpuWatts = values.gpuWatts
        diskRead = values.diskRead
        diskWrite = values.diskWrite
        networkIn = values.networkIn
        networkOut = values.networkOut
        chipCelsius = values.chipCelsius
    }

    /// Bytes per second read and written.
    public var disk: Double { diskRead + diskWrite }
    /// Bytes per second received and sent.
    public var network: Double { networkIn + networkOut }

    /// As a flight-recorder figure set, for a record of one update.
    public var values: HistoryValues {
        var values = HistoryValues()
        values.cpu = cpu
        values.cpuPeak = cpu
        values.memory = memory
        values.memoryPressure = memoryPressure
        values.swapUsed = swapUsed
        values.gpu = gpu
        values.systemWatts = systemWatts
        values.cpuWatts = cpuWatts
        values.gpuWatts = gpuWatts
        values.diskRead = diskRead
        values.diskWrite = diskWrite
        values.networkIn = networkIn
        values.networkOut = networkOut
        values.chipCelsius = chipCelsius
        return values
    }
}

/// What `SpikeTriggers` holds each figure to.
public struct SpikeThresholds: Sendable, Equatable {
    /// The share of the whole CPU that starts a busy stretch, and that the
    /// stretch must average over `sustain` seconds.
    public var cpu = 0.8
    /// The share a busy stretch carries on at, so a dip of a few points
    /// doesn't end it and start another.
    public var cpuRelease = 0.7
    /// Seconds a busy stretch or a burst must last before it counts.
    public var sustain: TimeInterval = 10
    /// A disk or network burst starts at this many times the usual rate...
    public var burstFactor = 4.0
    /// ...and carries on while above this many times it.
    public var burstRelease = 2.0
    /// Rates under these never count as a burst however quiet the usual
    /// rate, in bytes per second: an idle Mac's usual rate is near nothing,
    /// and four times nothing is still nothing.
    public var diskFloor = 64.0 * 1_048_576
    public var networkFloor = 8.0 * 1_048_576
    /// The usual rate is an average that forgets over about this many seconds.
    public var baselineSeconds: TimeInterval = 300
    /// Seconds of rates the usual rate needs before a burst can count.
    public var warmUp: TimeInterval = 60
    /// Seconds after a kind triggers before it can trigger again.
    public var cooldown: TimeInterval = 600
    /// An update further than this from the previous one (updates were
    /// paused, the Mac slept) ends every stretch, and isn't counted in one.
    public var gap: TimeInterval = 15

    public init() {}
}

/// Watches each update's figures for the moments worth keeping a detailed
/// capture of: the whole CPU busy for a while, memory or thermal pressure
/// rising, disk or network traffic in a burst well above its usual rate.
///
/// Each kind has hysteresis (a busy stretch starts at one figure and ends
/// at a lower one; a pressure must fall back to normal) and is disarmed once
/// it triggers until its condition ends, then cools down for `cooldown`
/// seconds, so one incident makes one trigger. A disk or network burst is
/// measured against its usual rate, an exponential average that forgets
/// over `baselineSeconds` and stands still during a burst. Fed once an
/// update: a few comparisons and no allocation, unless something triggers.
public struct SpikeTriggers: Sendable {
    /// A run of updates above a threshold.
    private struct Stretch {
        var since: Date?
        var sum = 0.0
        var covered = 0.0

        /// Feeds `value` into a stretch that starts at `enter` and carries
        /// on while at least `release`. Returns the stretch's average once
        /// it has lasted `sustain` seconds and averages at least `enter`; nil
        /// before that, and when the value falls out of it, which ends it.
        mutating func add(_ value: Double, enter: Double, release: Double, sample: SpikeSample, sustain: TimeInterval) -> Double? {
            let high = since == nil ? value >= enter : value >= release
            guard high, value.isFinite else {
                self = Stretch()
                return nil
            }
            if since == nil { since = sample.time.addingTimeInterval(-sample.interval) }
            sum += value * sample.interval
            covered += sample.interval
            let average = sum / covered
            return covered >= sustain - 0.001 && average >= enter ? average : nil
        }
    }

    /// Whether a kind may trigger: armed until it does, again once its
    /// condition ends, and never within `cooldown` of the last time.
    private struct Gate {
        var armed = true
        var last: Date?

        func allows(_ time: Date, cooldown: TimeInterval) -> Bool {
            armed && (last.map { time.timeIntervalSince($0) >= cooldown } ?? true)
        }
    }

    /// An exponential average of a rate, and the seconds it has seen.
    private struct Baseline {
        var value = 0.0
        var covered = 0.0

        mutating func add(_ rate: Double, interval: TimeInterval, over seconds: TimeInterval) {
            guard rate.isFinite else { return }
            value = covered == 0 ? rate : value + (rate - value) * (1 - exp(-interval / max(seconds, 1)))
            covered += interval
        }
    }

    public let thresholds: SpikeThresholds
    private var cpuStretch = Stretch()
    private var diskStretch = Stretch()
    private var networkStretch = Stretch()
    private var memorySince: Date?
    private var thermalSince: Date?
    private var cpuGate = Gate()
    private var memoryGate = Gate()
    private var thermalGate = Gate()
    private var diskGate = Gate()
    private var networkGate = Gate()
    private var diskBaseline = Baseline()
    private var networkBaseline = Baseline()
    private var last: Date?

    public init(thresholds: SpikeThresholds = SpikeThresholds()) {
        self.thresholds = thresholds
    }

    /// Takes one update's figures and returns what triggered on it, usually nothing.
    public mutating func update(_ sample: SpikeSample) -> [SpikeTrigger] {
        let time = sample.time
        let resumed = last.map { time.timeIntervalSince($0) > thresholds.gap || time < $0 } ?? false
        last = time
        // A pause or sleep ends every stretch; this update, which covers it, starts none.
        if resumed || sample.interval > thresholds.gap {
            endStretches()
            return levels(sample)
        }
        guard sample.interval > 0 else { return [] }
        var fired = levels(sample)
        if let trigger = cpu(sample) { fired.append(trigger) }
        if let trigger = burst(.disk, rate: sample.disk, floor: thresholds.diskFloor, sample: sample) { fired.append(trigger) }
        if let trigger = burst(.network, rate: sample.network, floor: thresholds.networkFloor, sample: sample) { fired.append(trigger) }
        return fired
    }

    /// Whether `kind`'s condition holds as of the last update: a busy
    /// stretch or burst under way, or a pressure above normal.
    public func isActive(_ kind: SpikeKind) -> Bool {
        switch kind {
        case .cpu: cpuStretch.since != nil
        case .memory: memorySince != nil
        case .thermal: thermalSince != nil
        case .disk: diskStretch.since != nil
        case .network: networkStretch.since != nil
        }
    }

    /// A trigger of `kind` on `sample` whatever its figures, for a debug
    /// build's forced capture. It counts like any other: the kind cools down.
    public mutating func force(_ kind: SpikeKind, on sample: SpikeSample) -> SpikeTrigger {
        let time = sample.time
        let since = time.addingTimeInterval(-sample.interval)
        let trigger = switch kind {
        case .cpu: SpikeTrigger(kind: kind, time: time, since: since, figure: sample.cpu, threshold: thresholds.cpu)
        case .memory: SpikeTrigger(kind: kind, time: time, since: since, figure: sample.memoryPressure, threshold: 0,
                                   level: sample.pressure == .normal ? MemoryPressure.warning.rawValue : sample.pressure.rawValue)
        case .thermal: SpikeTrigger(kind: kind, time: time, since: since, figure: Self.ordinal(sample.thermal), threshold: 0,
                                    level: Self.ordinal(sample.thermal) < 2 ? ThermalState.serious.rawValue : sample.thermal.rawValue)
        case .disk: SpikeTrigger(kind: kind, time: time, since: since, figure: sample.disk, threshold: thresholds.diskFloor,
                                 baseline: diskBaseline.value)
        case .network: SpikeTrigger(kind: kind, time: time, since: since, figure: sample.network, threshold: thresholds.networkFloor,
                                    baseline: networkBaseline.value)
        }
        modifyGate(kind) { $0 = Gate(armed: false, last: time) }
        return trigger
    }

    /// Thermal pressure as a number: 0 nominal, 1 fair, 2 serious, 3 critical.
    public static func ordinal(_ state: ThermalState) -> Double {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    // MARK: - Kinds

    /// Memory and thermal pressure, which trigger on the update that raises them.
    private mutating func levels(_ sample: SpikeSample) -> [SpikeTrigger] {
        var fired: [SpikeTrigger] = []
        let time = sample.time
        let start = time.addingTimeInterval(-min(sample.interval, thresholds.gap))
        if sample.pressure != .normal {
            if memorySince == nil { memorySince = start }
            if memoryGate.allows(time, cooldown: thresholds.cooldown) {
                memoryGate = Gate(armed: false, last: time)
                fired.append(SpikeTrigger(kind: .memory, time: time, since: memorySince ?? start, figure: sample.memoryPressure,
                                          threshold: 0, level: sample.pressure.rawValue))
            }
        } else {
            memorySince = nil
            memoryGate.armed = true
        }
        if sample.thermal == .serious || sample.thermal == .critical {
            if thermalSince == nil { thermalSince = start }
            if thermalGate.allows(time, cooldown: thresholds.cooldown) {
                thermalGate = Gate(armed: false, last: time)
                fired.append(SpikeTrigger(kind: .thermal, time: time, since: thermalSince ?? start, figure: Self.ordinal(sample.thermal),
                                          threshold: 0, level: sample.thermal.rawValue))
            }
        } else {
            thermalSince = nil
            thermalGate.armed = true
        }
        return fired
    }

    private mutating func cpu(_ sample: SpikeSample) -> SpikeTrigger? {
        guard let average = cpuStretch.add(sample.cpu, enter: thresholds.cpu, release: thresholds.cpuRelease, sample: sample,
                                           sustain: thresholds.sustain) else {
            if cpuStretch.since == nil { cpuGate.armed = true }
            return nil
        }
        guard cpuGate.allows(sample.time, cooldown: thresholds.cooldown) else { return nil }
        cpuGate = Gate(armed: false, last: sample.time)
        return SpikeTrigger(kind: .cpu, time: sample.time, since: cpuStretch.since ?? sample.time, figure: average, threshold: thresholds.cpu)
    }

    /// A disk or network burst against its usual rate, which learns only
    /// outside bursts and must have seen `warmUp` seconds first.
    private mutating func burst(_ kind: SpikeKind, rate: Double, floor: Double, sample: SpikeSample) -> SpikeTrigger? {
        var stretch = kind == .disk ? diskStretch : networkStretch
        var baseline = kind == .disk ? diskBaseline : networkBaseline
        defer {
            if kind == .disk {
                diskStretch = stretch
                diskBaseline = baseline
            } else {
                networkStretch = stretch
                networkBaseline = baseline
            }
        }
        guard baseline.covered >= thresholds.warmUp else {
            baseline.add(rate, interval: sample.interval, over: thresholds.baselineSeconds)
            return nil
        }
        let enter = max(floor, baseline.value * thresholds.burstFactor)
        let release = max(floor / 2, baseline.value * thresholds.burstRelease)
        guard let average = stretch.add(rate, enter: enter, release: release, sample: sample, sustain: thresholds.sustain) else {
            if stretch.since == nil {
                baseline.add(rate, interval: sample.interval, over: thresholds.baselineSeconds)
                modifyGate(kind) { $0.armed = true }
            }
            return nil
        }
        var allowed = false
        let cooldown = thresholds.cooldown
        modifyGate(kind) { gate in
            allowed = gate.allows(sample.time, cooldown: cooldown)
            if allowed { gate = Gate(armed: false, last: sample.time) }
        }
        guard allowed else { return nil }
        return SpikeTrigger(kind: kind, time: sample.time, since: stretch.since ?? sample.time, figure: average, threshold: enter,
                            baseline: baseline.value)
    }

    /// After a pause: what comes next is another stretch, and a pressure
    /// still raised counts from the update after it. A trigger's cooldown
    /// still holds, and a pressure that never fell back stays disarmed.
    private mutating func endStretches() {
        cpuStretch = Stretch()
        diskStretch = Stretch()
        networkStretch = Stretch()
        memorySince = nil
        thermalSince = nil
        cpuGate.armed = true
        diskGate.armed = true
        networkGate.armed = true
    }

    private mutating func modifyGate(_ kind: SpikeKind, _ change: (inout Gate) -> Void) {
        switch kind {
        case .cpu: change(&cpuGate)
        case .memory: change(&memoryGate)
        case .thermal: change(&thermalGate)
        case .disk: change(&diskGate)
        case .network: change(&networkGate)
        }
    }
}
