import Foundation

/// The mini monitor's figures for one tick, or averaged over a step.
public struct MiniMonitorFigures: Sendable, Equatable {
    /// The whole CPU's busy share, 0 to 1.
    public var cpu: Double
    /// Memory used, in bytes, and as a share of physical memory.
    public var memoryUsed: Double
    public var memoryFraction: Double
    public var pressure: MemoryPressure
    /// The first GPU's load, 0 to 1; nil where it isn't reported.
    public var gpu: Double?
    /// Bytes a second over the primary network links, and over every disk.
    public var networkIn: Double
    public var networkOut: Double
    public var diskRead: Double
    public var diskWrite: Double
    /// The whole system's draw; nil where it isn't measured.
    public var watts: Double?

    public init(cpu: Double, memoryUsed: Double, memoryFraction: Double, pressure: MemoryPressure, gpu: Double?,
                networkIn: Double, networkOut: Double, diskRead: Double, diskWrite: Double, watts: Double?) {
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryFraction = memoryFraction
        self.pressure = pressure
        self.gpu = gpu
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.watts = watts
    }

    /// As the Overview's cards total them: the primary links, every disk.
    public init(_ snapshot: SystemSnapshot) {
        var networkIn = 0.0
        var networkOut = 0.0
        for link in snapshot.network where link.isPrimary {
            networkIn += link.receivedBytesPerSecond
            networkOut += link.sentBytesPerSecond
        }
        var diskRead = 0.0
        var diskWrite = 0.0
        for disk in snapshot.disks {
            diskRead += disk.readBytesPerSecond
            diskWrite += disk.writeBytesPerSecond
        }
        self.init(cpu: snapshot.cpu.usage, memoryUsed: Double(snapshot.memory.used),
                  memoryFraction: snapshot.memory.usedFraction, pressure: snapshot.memory.pressure,
                  gpu: snapshot.gpus.first?.deviceUtilization, networkIn: networkIn, networkOut: networkOut,
                  diskRead: diskRead, diskWrite: diskWrite, watts: snapshot.power.systemWatts)
    }
}

/// What the mini monitor draws: the latest step's figures and each
/// meter's last `MiniMonitorFeed.points` steps, oldest first.
public struct MiniMonitorReading: Sendable, Equatable {
    public var figures: MiniMonitorFigures?
    public var cpu: [Double] = []
    public var memory: [Double] = []
    public var gpu: [Double] = []
    public var networkIn: [Double] = []
    public var networkOut: [Double] = []
    public var diskRead: [Double] = []
    public var diskWrite: [Double] = []
    public var power: [Double] = []
    /// Seconds between steps.
    public var step: TimeInterval = 1

    public init() {}
}

/// The mini monitor's own short histories, fed every tick while it's on,
/// shown or not, so it never needs the main window's published state.
/// Ticks are averaged into steps of the chosen update speed, never under a
/// second: a visible window's half-second ticks make one point a second,
/// as a hidden window's ticks do, so showing or hiding the main window
/// leaves the graphs as they are. A sleep gap or a new step starts them again.
public struct MiniMonitorFeed: Sendable {
    /// Steps each graph holds: a minute at one a second.
    public static let points = 60

    public private(set) var reading = MiniMonitorReading()
    private var cpu = History<Double>(capacity: points)
    private var memory = History<Double>(capacity: points)
    private var gpu = History<Double>(capacity: points)
    private var networkIn = History<Double>(capacity: points)
    private var networkOut = History<Double>(capacity: points)
    private var diskRead = History<Double>(capacity: points)
    private var diskWrite = History<Double>(capacity: points)
    private var power = History<Double>(capacity: points)
    private var pending = Pending()

    /// Ticks so far towards the next step.
    private struct Pending {
        var duration = 0.0
        var cpu = 0.0
        var memoryUsed = 0.0
        var memoryFraction = 0.0
        var networkIn = 0.0
        var networkOut = 0.0
        var diskRead = 0.0
        var diskWrite = 0.0
        var gpu = 0.0
        var gpuDuration = 0.0
        var watts = 0.0
        var wattsDuration = 0.0

        mutating func add(_ figures: MiniMonitorFigures, weight: Double) {
            duration += weight
            cpu += figures.cpu * weight
            memoryUsed += figures.memoryUsed * weight
            memoryFraction += figures.memoryFraction * weight
            networkIn += figures.networkIn * weight
            networkOut += figures.networkOut * weight
            diskRead += figures.diskRead * weight
            diskWrite += figures.diskWrite * weight
            if let load = figures.gpu {
                gpu += load * weight
                gpuDuration += weight
            }
            if let draw = figures.watts {
                watts += draw * weight
                wattsDuration += weight
            }
        }

        /// The averages, with the latest tick's pressure.
        func mean(pressure: MemoryPressure) -> MiniMonitorFigures {
            MiniMonitorFigures(cpu: cpu / duration, memoryUsed: memoryUsed / duration, memoryFraction: memoryFraction / duration,
                               pressure: pressure, gpu: gpuDuration > 0 ? gpu / gpuDuration : nil,
                               networkIn: networkIn / duration, networkOut: networkOut / duration,
                               diskRead: diskRead / duration, diskWrite: diskWrite / duration,
                               watts: wattsDuration > 0 ? watts / wattsDuration : nil)
        }
    }

    public init() {}

    /// Adds a tick `interval` seconds long at a step of `step` seconds (the
    /// update speed, at least a second). Returns whether it finished a step,
    /// so `reading` has changed.
    @discardableResult
    public mutating func add(_ figures: MiniMonitorFigures, interval: TimeInterval, step: TimeInterval) -> Bool {
        let step = max(step, 1)
        if step != reading.step {
            reset()
            reading.step = step
        }
        guard interval > 0 else { return false }
        // Rates over a sleep would be drawn as a step's worth of activity.
        guard !BackgroundGraphPolicy.isGap(interval: interval, step: step) else {
            reset()
            return false
        }
        pending.add(figures, weight: interval)
        // A step's ticks seldom add up to it exactly; within half a tick will do.
        guard pending.duration >= step - interval / 2 else { return false }
        let mean = pending.mean(pressure: figures.pressure)
        pending = Pending()
        cpu.append(mean.cpu)
        memory.append(mean.memoryFraction)
        if let load = mean.gpu { gpu.append(load) }
        networkIn.append(mean.networkIn)
        networkOut.append(mean.networkOut)
        diskRead.append(mean.diskRead)
        diskWrite.append(mean.diskWrite)
        if let draw = mean.watts { power.append(draw) }
        reading.figures = mean
        reading.cpu = cpu.values
        reading.memory = memory.values
        reading.gpu = gpu.values
        reading.networkIn = networkIn.values
        reading.networkOut = networkOut.values
        reading.diskRead = diskRead.values
        reading.diskWrite = diskWrite.values
        reading.power = power.values
        return true
    }

    /// Starts every graph again, keeping the step.
    public mutating func reset() {
        let step = reading.step
        self = MiniMonitorFeed()
        reading.step = step
    }
}
