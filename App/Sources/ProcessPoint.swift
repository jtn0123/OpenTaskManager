import AppKit
import OTMKit

/// Per-process values kept for the inspector's graphs and the "by app" charts.
/// There's one per process per sample across a whole graph window, so they're
/// held as `Float`, half the size of `Double`, which no graph can tell apart:
/// a window of 300 costs about what 120 did before.
struct ProcessPoint: Sendable {
    private let cpu: Float
    private let footprint: Float
    private let gpu: Float
    private let power: Float

    init(cpuPercent: Double, memory: UInt64, gpuFraction: Double, powerWatts: Double) {
        cpu = Float(cpuPercent)
        footprint = Float(memory)
        gpu = Float(gpuFraction)
        power = Float(powerWatts)
    }

    /// 100 = one core, as `ProcessSample.cpuPercent`.
    var cpuPercent: Double { Double(cpu) }
    /// Bytes, as `ProcessSample.memory`.
    var memory: UInt64 { UInt64(max(footprint, 0)) }
    var gpuFraction: Double { Double(gpu) }
    var powerWatts: Double { Double(power) }

    subscript(figure: ProcessFigure) -> Double {
        switch figure {
        case .cpu: Double(cpu)
        case .memory: Double(footprint)
        case .gpu: Double(gpu)
        case .power: Double(power)
        }
    }
}

/// A figure a process's history keeps, to rank and graph apps by.
enum ProcessFigure {
    /// Activity Monitor-style percent: 100 = one core.
    case cpu
    /// Footprint in bytes.
    case memory
    /// Share of the GPU's time.
    case gpu
    /// Watts.
    case power
}

/// A process's figures added up over its history, kept as samples come and
/// go, so ranking apps over the window reads one total per process instead
/// of walking every history every tick.
struct ProcessTotal: Sendable {
    private var cpu = RunningSum()
    private var memory = RunningSum()
    private var gpu = RunningSum()
    private var power = RunningSum()

    subscript(figure: ProcessFigure) -> Double {
        switch figure {
        case .cpu: cpu.value
        case .memory: memory.value
        case .gpu: gpu.value
        case .power: power.value
        }
    }

    /// Counts `point` in as its history takes it.
    mutating func add(_ point: ProcessPoint) {
        cpu.add(point[.cpu])
        memory.add(point[.memory])
        gpu.add(point[.gpu])
        power.add(point[.power])
    }

    /// Takes `point` out as its history drops it.
    mutating func remove(_ point: ProcessPoint) {
        cpu.remove(point[.cpu])
        memory.remove(point[.memory])
        gpu.remove(point[.gpu])
        power.remove(point[.power])
    }
}

/// One app's use of a resource over time, for the stacked "by app" graphs.
struct AppSeries: Identifiable {
    let id: Int64
    let name: String
    let icon: NSImage
    let values: [Double]

    var current: Double { values.last ?? 0 }
}
