import Foundation
import OTMKit

/// A line on one of Performance's main graphs, whose older time a squeezed
/// graph (`Settings.squeezesOlderTime`) draws to the left of its window.
enum OlderSeries: Hashable, Sendable {
    case cpu, cpuSystem
    /// A core type's average load, and its kernel part, by `CPUTopology.Tier.level`.
    case tier(Int), tierKernel(Int)
    case memoryApp, memoryWired, memoryCompressed, memoryCached, memoryPressure
    case gpuBusy(String), gpuRenderer(String), gpuTiler(String), gpuMemory(String)
    case diskActive(String), diskRead(String), diskWrite(String)
    case networkIn(String), networkOut(String)
    case power, powerPart(PowerComponent), powerRest, thermalPressure
    case hottest(SensorKind), chipAverage
}

extension AppModel {
    /// Puts this tick's figures for every main graph's lines into their
    /// older time, while Squeeze older time is on: every tick, the window
    /// shown or not, as the flight recorder's are, but into unobserved state
    /// that a graph reads when it next draws. A tick after sleep marks the
    /// stretch unrecorded rather than drawing its averaged rates.
    func recordOlderTime(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        guard squeezesOlderTime else { return }
        let step = max(samplingInterval, 0.1)
        if BackgroundGraphPolicy.isGap(interval: snapshot.interval, step: max(step, 1)) {
            olderTime.gap(samples: Int(snapshot.interval / step))
            return
        }
        guard snapshot.interval > 0 else { return }
        #if DEBUG
        if olderTime.isEmpty, OlderTimeFixture.enabled { fillOlderTimeFixture(snapshot, sensors: sensors) }
        #endif
        // A hidden tick at twice the graphs' step (Fast, hidden) counts twice.
        olderTime.startTick(weight: Int((backgroundSampling.interval / step).rounded()))
        forEachOlderReading(snapshot, sensors: sensors) { olderTime.add($1, for: $0) }
        olderTime.finishTick()
    }

    /// Each main graph line's reading in `snapshot`, as the graphs' own
    /// histories take it.
    func forEachOlderReading(_ snapshot: SystemSnapshot, sensors: SensorSample?, _ body: (OlderSeries, Double) -> Void) {
        body(.cpu, snapshot.cpu.usage)
        body(.cpuSystem, snapshot.cpu.system)
        for tier in topology.tiers {
            body(.tier(tier.level), tierAverage(snapshot.cpu.coreUsage, level: tier.level))
            body(.tierKernel(tier.level), tierAverage(snapshot.cpu.coreSystem, level: tier.level))
        }
        let memory = snapshot.memory
        body(.memoryApp, Double(memory.app))
        body(.memoryWired, Double(memory.wired))
        body(.memoryCompressed, Double(memory.compressed))
        body(.memoryCached, Double(memory.cached))
        body(.memoryPressure, MemoryHistory.pressure(memory))
        for gpu in snapshot.gpus {
            if let busy = gpu.deviceUtilization { body(.gpuBusy(gpu.id), busy) }
            body(.gpuRenderer(gpu.id), gpu.rendererUtilization ?? 0)
            body(.gpuTiler(gpu.id), gpu.tilerUtilization ?? 0)
            body(.gpuMemory(gpu.id), Double(gpu.memoryInUse ?? 0))
        }
        for disk in snapshot.disks {
            body(.diskActive(disk.id), disk.activeFraction)
            body(.diskRead(disk.id), disk.readBytesPerSecond)
            body(.diskWrite(disk.id), disk.writeBytesPerSecond)
        }
        for link in snapshot.network {
            body(.networkIn(link.id), link.receivedBytesPerSecond)
            body(.networkOut(link.id), link.sentBytesPerSecond)
        }
        let power = snapshot.power
        body(.power, power.systemWatts ?? 0)
        for part in [PowerComponent.cpu, .gpu, .ane, .dram] {
            body(.powerPart(part), power.components?.watts(part) ?? 0)
        }
        body(.powerRest, PowerHistory.rest(power))
        body(.thermalPressure, power.thermalState.level)
        if let sensors, !sensors.isEmpty {
            for kind in SensorKind.allCases {
                if let celsius = sensors.hottest(kind) { body(.hottest(kind), celsius) }
            }
            if let average = sensors.average(.chip) { body(.chipAverage, average) }
        }
    }

    /// The older time of a main graph's lines, in their order, while
    /// Squeeze older time is on; nil otherwise. A line with none yet gets none.
    func squeeze(_ lines: [OlderSeries]) -> GraphSqueeze? {
        guard squeezesOlderTime else { return nil }
        return GraphSqueeze(older: lines.map { olderTime.buckets($0) ?? [] },
                            peak: lines.map { olderTime.peak($0) }.max() ?? 0,
                            revision: olderTime.revision, bucketSize: olderTime.bucketSize)
    }

    /// The average of `loads` over one core type's logical CPUs, as `tierHistory` takes it.
    private func tierAverage(_ loads: [Double], level: Int) -> Double {
        var sum = 0.0
        var count = 0
        for (cpu, tier) in topology.tierForCPU.enumerated() where tier == level && cpu < loads.count {
            sum += loads[cpu]
            count += 1
        }
        return count > 0 ? sum / Double(count) : .nan
    }
}
