import Foundation
import OTMKit

// `otm inspect` and `otm threads`: one process in depth, as the app's
// inspector shows it, and its threads with their CPU.

struct Inspection: Encodable {
    /// One of the processes that started it, oldest first.
    struct Ancestor: Encodable {
        let pid: Int32
        let name: String
    }

    let process: ProcessSample?
    let arguments: ProcessArguments?
    let currentDirectory: String?
    let openFiles: [OpenFile]?
    let diagnostics: ProcessDiagnostics?
    let ancestry: [Ancestor]
}

/// `otm inspect PID [--json]`.
func inspectCommand(_ options: Options, monitor: SystemMonitor) async {
    guard let pid = options.positional.first.flatMap(Int32.init) else { fail("inspect needs a PID") }
    let snapshot = await monitor.sample()
    guard let process = snapshot.processes.first(where: { $0.pid == pid }) else { fail("no process with PID \(pid)") }
    let ancestry = ProcessAncestry.build(for: process, in: snapshot.processes)
    let diagnostics = ProcessDetailReader.diagnostics(process.identity)
    let inspection = Inspection(
        process: process,
        arguments: ProcessInspector.arguments(of: pid),
        currentDirectory: ProcessInspector.currentDirectory(of: pid),
        openFiles: ProcessInspector.openFiles(of: pid),
        diagnostics: diagnostics,
        ancestry: ancestry.ancestors.map { Inspection.Ancestor(pid: $0.pid, name: $0.name) }
    )
    guard !options.json else { return printJSON(inspection) }
    print("\(process.name) (PID \(process.pid), parent \(process.parentPID), user \(process.userName))")
    print("Path:       \(process.executablePath ?? "unknown")")
    print("Directory:  \(inspection.currentDirectory ?? "unavailable")")
    print("Command:    \(inspection.arguments?.commandLine ?? "unavailable (another user's process)")")
    diagnosticsSummary(diagnostics, ancestry: ancestry, nice: process.nice).forEach { print($0) }
    if process.hasHeldNeuralMemory {
        let now = Format.bytes(process.neuralMemory ?? 0), peak = Format.bytes(process.neuralMemoryPeak ?? 0)
        print("ANE memory: \(now) now, \(peak) at most (held for the Neural Engine, apart from the footprint)")
    }
    if let environment = inspection.arguments?.environment, !environment.isEmpty {
        print("Environment (\(environment.count)):")
        for variable in environment { print("  \(variable.name)=\(variable.value)") }
    }
    if let files = inspection.openFiles {
        print("Open files (\(files.count)):")
        for file in files {
            let kind = file.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(pad(String(file.descriptor), 5, right: true))  \(kind)\(file.detail)")
        }
    }
}

/// `otm threads PID [--sort KEY] [--interval SECONDS] [--json]`: two readings
/// `--interval` apart, so each thread's CPU is over that time.
func threadsCommand(_ options: Options) async throws {
    guard let pid = options.positional.first.flatMap(Int32.init) else { fail("threads needs a PID") }
    guard let identity = ProcessDetailReader.identity(of: pid) else { fail("no process with PID \(pid)") }
    let keys: [String: ThreadSortKey] = ["cpu": .cpu, "time": .cpuTime, "name": .name, "id": .id, "state": .state, "priority": .priority]
    guard let key = keys[options.sort] else { fail("--sort takes cpu, time, name, id, state or priority") }

    var tracker = ThreadActivityTracker()
    var rows: [ThreadActivity] = []
    for reading in 0..<2 {
        if reading > 0 { try await Task.sleep(for: .seconds(max(options.interval, 0.1))) }
        switch ProcessDetailReader.threads(identity) {
        case let .success(threads):
            rows = tracker.update(threads, of: identity, at: ProcessInfo.processInfo.systemUptime)
        case .failure(.denied):
            fail("the threads of PID \(pid) aren't readable without admin rights: macOS shows them only for your own processes, "
                + "or to root (sudo)")
        case .failure:
            fail("PID \(pid) ended")
        }
    }
    // Busiest first, or A to Z by name; ascending for ID.
    rows = ThreadActivitySort.sorted(rows, by: key, ascending: key == .name || key == .id)
    if options.json {
        printJSON(rows)
    } else {
        print(threadTable(rows))
    }
}

func threadTable(_ rows: [ThreadActivity]) -> String {
    let summary = ThreadSummary(rows)
    var lines = [
        "\(summary.count) threads, \(summary.running) running, \(Format.fixed(summary.cpuPercent ?? 0, 1))% CPU (100% = one core)",
        "",
        pad("THREAD ID", 12, right: true) + pad("CPU%", 7, right: true) + pad("CPU TIME", 11, right: true)
            + "  " + pad("STATE", 9) + pad("PRI", 4, right: true) + "  NAME",
    ]
    for row in rows {
        lines.append(
            // Hexadecimal, as `sample` and spindump print thread IDs.
            pad("0x" + String(row.thread.id, radix: 16), 12, right: true)
                + pad(row.cpuPercent.map { Format.fixed($0, 1) } ?? "-", 7, right: true)
                + pad(Format.cpuTime(row.thread.cpuTime), 11, right: true)
                + "  " + pad(row.thread.state.title, 9)
                + pad(String(row.thread.priority), 4, right: true)
                + "  " + (row.thread.name ?? "-")
        )
    }
    return lines.joined(separator: "\n")
}

/// `otm inspect`'s lines on memory, faults, scheduling and ancestry.
func diagnosticsSummary(_ diagnostics: ProcessDiagnostics, ancestry: ProcessAncestry, nice: Int32) -> [String] {
    func text<T>(_ field: ProcessField<T>, _ format: (T) -> String) -> String {
        switch field {
        case let .value(value): format(value)
        case .denied: "needs admin rights"
        case .unavailable: "unavailable"
        }
    }
    let count = { (value: UInt64) in value.formatted() }
    var lines = [
        "Memory:     footprint \(text(diagnostics.footprint, Format.bytes)), peak \(text(diagnostics.peakFootprint, Format.bytes)), "
            + "resident \(text(diagnostics.resident, Format.bytes))",
        "Faults:     \(text(diagnostics.faults, count)) page faults, \(text(diagnostics.pageIns, count)) page-ins, "
            + "\(text(diagnostics.copyOnWriteFaults, count)) copy-on-write",
        "Scheduling: nice \(nice), base priority \(text(diagnostics.basePriority) { String($0) }), "
            + "\(text(diagnostics.policy) { $0.title.lowercased() }); \(text(diagnostics.contextSwitches, count)) context switches, "
            + "\(text(diagnostics.systemCalls, count)) system calls",
    ]
    // Classes under half a percent would print as 0%.
    if let qos = diagnostics.qos.value?.filter({ $0.fraction >= 0.005 }), !qos.isEmpty {
        lines.append("CPU by QoS: " + qos.map { "\($0.qos.title.lowercased()) \(Format.percent($0.fraction))" }.joined(separator: ", "))
    }
    var chain = ancestry.chain.map { "\($0.name) (\($0.pid))" }
    if let gap = ancestry.gap { chain.insert("PID \(gap.pid) (ended)", at: 0) }
    lines.append("Ancestry:   " + chain.joined(separator: " › "))
    return lines
}
