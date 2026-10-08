import Foundation
import OTMKit

/// Memory composition over time, one history per kind of page.
struct MemoryHistory {
    var app = History<Double>(capacity: AppModel.historyCapacity)
    var wired = History<Double>(capacity: AppModel.historyCapacity)
    var compressed = History<Double>(capacity: AppModel.historyCapacity)
    var cached = History<Double>(capacity: AppModel.historyCapacity)
    var swapUsed = History<Double>(capacity: AppModel.historyCapacity)
    /// 0...1, from the kernel's "memory available" level.
    var pressure = History<Double>(capacity: AppModel.historyCapacity)
    /// Bytes per second.
    var pageIns = History<Double>(capacity: AppModel.historyCapacity)
    var pageOuts = History<Double>(capacity: AppModel.historyCapacity)
    var swapIns = History<Double>(capacity: AppModel.historyCapacity)
    var swapOuts = History<Double>(capacity: AppModel.historyCapacity)
    var compressions = History<Double>(capacity: AppModel.historyCapacity)
    var decompressions = History<Double>(capacity: AppModel.historyCapacity)

    mutating func append(_ memory: MemorySample) {
        app.append(Double(memory.app))
        wired.append(Double(memory.wired))
        compressed.append(Double(memory.compressed))
        cached.append(Double(memory.cached))
        swapUsed.append(Double(memory.swapUsed))
        pressure.append(memory.availablePercent.map { 1 - Double($0) / 100 } ?? memory.usedFraction)
        pageIns.append(memory.pageInRate)
        pageOuts.append(memory.pageOutRate)
        swapIns.append(memory.swapInRate)
        swapOuts.append(memory.swapOutRate)
        compressions.append(memory.compressionRate)
        decompressions.append(memory.decompressionRate)
    }
}

/// Renderer, tiler and memory history for one GPU.
struct GPUHistory {
    var renderer = History<Double>(capacity: AppModel.historyCapacity)
    var tiler = History<Double>(capacity: AppModel.historyCapacity)
    var memoryInUse = History<Double>(capacity: AppModel.historyCapacity)
    /// Average clock while powered on, in MHz. An idle interval has no clock,
    /// so it repeats the last one rather than dropping the line to zero.
    var frequency = History<Double>(capacity: AppModel.historyCapacity)

    mutating func append(_ gpu: GPUSample) {
        renderer.append(gpu.rendererUtilization ?? 0)
        tiler.append(gpu.tilerUtilization ?? 0)
        memoryInUse.append(Double(gpu.memoryInUse ?? 0))
        frequency.append(gpu.frequencyMHz ?? frequency.last ?? 0)
    }
}

/// Whole-system power split into parts of the chip, and energy used since launch.
struct PowerHistory {
    var cpu = History<Double>(capacity: AppModel.historyCapacity)
    var gpu = History<Double>(capacity: AppModel.historyCapacity)
    var ane = History<Double>(capacity: AppModel.historyCapacity)
    var dram = History<Double>(capacity: AppModel.historyCapacity)
    /// The system figure minus the chip's parts: display, SSD, radios, fans,
    /// power conversion. Never negative, though the system figure lags a beat.
    var rest = History<Double>(capacity: AppModel.historyCapacity)
    /// Per CPU cluster, keyed by name: watts, average clock (MHz) and share of
    /// time running. An idle cluster repeats its last clock, like `GPUHistory`.
    var clusterWatts: [String: History<Double>] = [:]
    var clusterFrequency: [String: History<Double>] = [:]
    var clusterActive: [String: History<Double>] = [:]
    var adapterInput = History<Double>(capacity: AppModel.historyCapacity)
    /// Into the battery; negative while it discharges.
    var battery = History<Double>(capacity: AppModel.historyCapacity)
    var integral = PowerEnergy()
    var energy: Double { integral.joules }
    var componentEnergy: [PowerComponent: Double] { integral.components }
    var seconds: Double { integral.seconds }

    mutating func append(_ power: PowerSample, interval: TimeInterval, keepingEnergy: Bool = true) {
        let parts = power.components
        cpu.append(parts?.watts(.cpu) ?? 0)
        gpu.append(parts?.watts(.gpu) ?? 0)
        ane.append(parts?.watts(.ane) ?? 0)
        dram.append(parts?.watts(.dram) ?? 0)
        if let system = power.systemWatts, let parts {
            rest.append(max(system - parts.total, 0))
        } else {
            rest.append(0)
        }
        for cluster in parts?.clusters ?? [] {
            clusterWatts[cluster.name, default: Self.history()].append(cluster.watts ?? 0)
            var clock = clusterFrequency[cluster.name] ?? Self.history()
            clock.append(cluster.frequencyMHz ?? clock.last ?? 0)
            clusterFrequency[cluster.name] = clock
            clusterActive[cluster.name, default: Self.history()].append(cluster.activeFraction ?? 0)
        }
        adapterInput.append(power.adapter?.inputWatts ?? 0)
        battery.append(power.adapter?.batteryWatts ?? power.battery?.watts ?? 0)

        if keepingEnergy { integral.add(power, interval: interval) }
    }

    /// Average whole-system draw since launch.
    var averageWatts: Double? { integral.averageWatts }

    private static func history() -> History<Double> {
        History(capacity: AppModel.historyCapacity)
    }
}

/// One user's CPU (100 = one core) and summed process memory over time.
struct UserHistory {
    var cpu = History<Double>(capacity: AppModel.userHistoryCapacity)
    var memory = History<Double>(capacity: AppModel.userHistoryCapacity)

    mutating func append(_ totals: UsageTotals) {
        cpu.append(totals.cpuPercent)
        memory.append(Double(totals.memory))
    }
}

enum UpdateSpeed: Double, CaseIterable, Identifiable {
    case fast = 0.5
    case normal = 1
    case slow = 2
    case verySlow = 5

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast (2× per second)"
        case .normal: "Normal (every second)"
        case .slow: "Slow (every 2 seconds)"
        case .verySlow: "Very slow (every 5 seconds)"
        }
    }
}

/// How per-process CPU is shown. macOS tools count 100% per core, so a busy
/// app on an 18-core Mac can read 1,200%; the default is share of the whole CPU.
struct CPUScale: Equatable {
    var relativeToSystem: Bool
    var logicalCores: Int

    /// Converts a per-process figure (100 = one core) to the chosen scale.
    func value(_ percentOfCore: Double) -> Double {
        guard relativeToSystem else { return percentOfCore }
        return min(percentOfCore / Double(max(logicalCores, 1)), 100)
    }

    func format(_ percentOfCore: Double) -> String {
        Format.fixed(value(percentOfCore), 1) + "%"
    }
}

/// Temperatures and fan speeds over time.
struct SensorHistory {
    private(set) var hottest: [SensorKind: History<Double>] = [:]
    private(set) var chipAverage = History<Double>(capacity: AppModel.historyCapacity)
    private(set) var fans: [Int: History<Double>] = [:]

    mutating func append(_ sample: SensorSample) {
        for kind in SensorKind.allCases {
            if let celsius = sample.hottest(kind) {
                hottest[kind, default: History(capacity: AppModel.historyCapacity)].append(celsius)
            }
        }
        if let average = sample.average(.chip) { chipAverage.append(average) }
        for fan in sample.fans {
            fans[fan.id, default: History(capacity: AppModel.historyCapacity)].append(fan.rpm)
        }
    }
}
