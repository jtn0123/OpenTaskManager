import Foundation
import OTMKit

// `otm ps` and `otm top`: the process table and its sort orders.

func sorted(_ processes: [ProcessSample], by key: String) -> [ProcessSample] {
    switch key {
    case "mem", "memory": processes.sorted { $0.memory > $1.memory }
    case "power", "energy": processes.sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }
    case "gpu": processes.sorted { ($0.gpuFraction ?? 0) > ($1.gpuFraction ?? 0) }
    case "ane", "neural":
        processes.sorted { ($0.neuralMemory ?? 0, $0.neuralMemoryPeak ?? 0) > ($1.neuralMemory ?? 0, $1.neuralMemoryPeak ?? 0) }
    case "disk": processes.sorted { $0.diskReadRate + $0.diskWriteRate > $1.diskReadRate + $1.diskWriteRate }
    case "pid": processes.sorted { $0.pid < $1.pid }
    case "name": processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    default: processes.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}

func processTable(_ snapshot: SystemSnapshot, options: Options) -> String {
    // Neural Engine memory only once some process has held any, so a Mac
    // without it (or before macOS 15) keeps the narrower table.
    let showsNeural = snapshot.processes.contains(where: \.hasHeldNeuralMemory)
    var lines = [
        pad("PID", 7, right: true) + "  " + pad("NAME", 28) + pad("CPU%", 7, right: true)
            + pad("MEM", 10, right: true) + pad("POWER", 9, right: true) + pad("GPU%", 6, right: true)
            + (showsNeural ? pad("ANE MEM", 10, right: true) : "")
            + pad("THR", 5, right: true) + pad("DISK/s", 11, right: true) + "  USER",
    ]
    for process in sorted(snapshot.processes, by: options.sort).prefix(options.count) {
        let marker = process.isRestricted ? "*" : " "
        let neural = process.hasHeldNeuralMemory ? Format.bytes(process.neuralMemory ?? 0) : "-"
        lines.append(
            pad(String(process.pid), 7, right: true) + " " + marker + pad(process.name, 28)
                + pad(Format.fixed(process.cpuPercent, 1), 7, right: true)
                + pad(Format.bytes(process.memory), 10, right: true)
                + pad(process.powerWatts.map(Format.watts) ?? "-", 9, right: true)
                + pad(process.gpuFraction.map { Format.fixed($0 * 100, 0) } ?? "-", 6, right: true)
                + (showsNeural ? pad(neural, 10, right: true) : "")
                + pad(process.threadCount > 0 ? String(process.threadCount) : "-", 5, right: true)
                + pad(Format.bytes(process.diskReadRate + process.diskWriteRate), 11, right: true)
                + "  " + process.userName
        )
    }
    return lines.joined(separator: "\n")
}
