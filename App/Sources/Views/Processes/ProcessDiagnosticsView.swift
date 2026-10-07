import OTMKit
import SwiftUI

extension AppModel {
    /// The process with this PID and start time, while it runs. A PID macOS
    /// has given to a later process doesn't count.
    func process(_ identity: ProcessIdentity) -> ProcessSample? {
        snapshot.flatMap { identity.find(in: $0.processes) }
    }

    /// The PIDs of those still running as themselves, for End Task and the
    /// like: an ended process's PID may belong to another one by now.
    func livePIDs(_ processes: Set<ProcessIdentity>) -> [Int32] {
        guard let snapshot, !processes.isEmpty else { return [] }
        return snapshot.processes.filter { processes.contains($0.identity) }.map(\.pid)
    }
}

extension CPUScale {
    /// One shown step (0.1%) in per-core percent, so sorts compare CPU as it
    /// reads and rows that read the same don't trade places every tick.
    var shownStep: Double {
        relativeToSystem ? 0.1 * Double(max(logicalCores, 1)) : 0.1
    }
}

/// Why the inspector has no figure for a field.
enum ProcessAccess {
    static let denied = "Needs admin rights"
    static let deniedHelp = "macOS reveals this only for your own processes, or to an administrator (root). "
        + "This one belongs to another user or to the system."
    static let unavailableHelp = "Not available: the process may have ended, or macOS doesn't count it for this one."
}

/// A row of the inspector's facts: the value, or why there isn't one.
struct ProcessFieldRow: View, Equatable {
    var label: String
    var field: ProcessField<String>
    var help: String?

    init(_ label: String, _ field: ProcessField<String>, help: String? = nil) {
        self.label = label
        self.field = field
        self.help = help
    }

    init(_ label: String, _ value: String, help: String? = nil) {
        self.init(label, .value(value), help: help)
    }

    /// So the values of the inspector's sections, each a grid of its own, line up.
    static let labelWidth: CGFloat = 100

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondaryText).help(help ?? "")
                .frame(minWidth: Self.labelWidth, alignment: .leading)
            switch field {
            case let .value(value):
                Text(value).textSelection(.enabled).help(help ?? "")
            case .denied:
                Text(ProcessAccess.denied).foregroundStyle(.secondaryText).help(ProcessAccess.deniedHelp)
            case .unavailable:
                Text("—").help(ProcessAccess.unavailableHelp)
            }
        }
        .font(.callout)
    }
}

/// A section's title in the inspector, as in the other details panes.
struct InspectorHeading: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Overview's Memory and Scheduling sections: the sampled figures, and
/// counters read for this one process each tick while the Overview shows.
/// Another user's or a system process isn't read: macOS refuses all of it,
/// so each field says so.
struct ProcessDiagnosticsSections: View {
    @Environment(AppModel.self) private var model
    var process: ProcessSample
    @State private var readings = Readings()
    @State private var showsMemoryHelp = false

    private struct Readings {
        var current: ProcessDiagnostics?
        var previous: ProcessDiagnostics?
    }

    var body: some View {
        let reading = shownReading
        let rates = ProcessRates(reading, since: readings.previous)
        VStack(alignment: .leading, spacing: 12) {
            memory(reading, rates: rates)
            scheduling(reading, rates: rates)
        }
        .onAppear(perform: read)
        .onChange(of: model.snapshot?.timestamp) { read() }
        .onChange(of: process.identity) { read() }
    }

    private var shownReading: ProcessDiagnostics {
        if process.isRestricted { return .unreadable(process.identity, at: 0, because: .denied) }
        if let current = readings.current, current.identity == process.identity { return current }
        return .unreadable(process.identity, at: 0, because: .unavailable)
    }

    /// A few libproc calls for the one process, so on the main actor.
    private func read() {
        guard !process.isRestricted else { return }
        let now = ProcessDetailReader.diagnostics(process.identity)
        let previous = readings.current?.identity == now.identity ? readings.current : nil
        readings = Readings(current: now, previous: previous)
    }

    // MARK: Memory

    private func memory(_ reading: ProcessDiagnostics, rates: ProcessRates) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorHeading("Memory")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ProcessFieldRow("Footprint", process.isRestricted ? .denied : .value(Format.bytes(process.memory)),
                                help: MemoryMeasure.footprint)
                ProcessFieldRow("Peak footprint", reading.peakFootprint.map { Format.bytes($0) }, help: Self.peakHelp)
                realMemoryRow
                if process.hasHeldNeuralMemory {
                    ProcessFieldRow("Neural Engine",
                                    "\(Format.bytes(process.neuralMemory ?? 0)) · \(Format.bytes(process.neuralMemoryPeak ?? 0)) at most",
                                    help: MemoryMeasure.neural)
                }
                ProcessFieldRow("Page faults", counted(reading.faults, rates.faults), help: Self.faultsHelp)
                ProcessFieldRow("Page-ins", counted(reading.pageIns, rates.pageIns), help: Self.pageInsHelp)
                ProcessFieldRow("Copy-on-write", reading.copyOnWriteFaults.map(Format.count), help: Self.copyOnWriteHelp)
            }
        }
    }

    /// Resident size, with what sets it apart from the footprint in a
    /// popover. For other users' processes, the one figure macOS gives.
    private var realMemoryRow: some View {
        GridRow {
            Text("Real memory").foregroundStyle(.secondaryText).help(MemoryMeasure.resident)
                .frame(minWidth: ProcessFieldRow.labelWidth, alignment: .leading)
            HStack(spacing: 4) {
                Text(Format.bytes(process.isRestricted ? process.memory : process.residentMemory)).textSelection(.enabled)
                Button {
                    showsMemoryHelp.toggle()
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondaryText)
                }
                .buttonStyle(.borderless)
                .help("Why real memory differs from the footprint")
                .accessibilityLabel("About the memory figures")
                .popover(isPresented: $showsMemoryHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MemoryMeasure.footprint)
                        Text(MemoryMeasure.resident)
                    }
                    .font(.explanation)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                }
            }
        }
        .font(.callout)
    }

    // MARK: Scheduling

    private func scheduling(_ reading: ProcessDiagnostics, rates: ProcessRates) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorHeading("Scheduling")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ProcessFieldRow("Nice", process.nice == 0 ? "0 (normal)" : String(process.nice), help: Self.niceHelp)
                ProcessFieldRow("Base priority", reading.basePriority.map { String($0) }, help: Self.basePriorityHelp)
                ProcessFieldRow("Policy", reading.policy.map(\.title), help: Self.policyHelp)
                ProcessFieldRow("Threads", threads(reading), help: "Its threads, and how many were on a core as they were read. "
                    + "The Threads tab lists them.")
                ProcessFieldRow("Context switches", counted(reading.contextSwitches, rates.contextSwitches), help: Self.switchesHelp)
                ProcessFieldRow("System calls", counted(reading.systemCalls, rates.systemCalls),
                                help: "System calls: requests to the kernel, BSD and Mach together, since it started and per second.")
                ProcessFieldRow("Mach messages", counted(reading.messages, rates.messages),
                                help: "Mach messages sent and received: how processes on macOS talk to each other and to the system.")
                ProcessFieldRow("CPU by QoS", reading.qos.map(Self.qosText), help: Self.qosHelp)
            }
        }
    }

    private func threads(_ reading: ProcessDiagnostics) -> ProcessField<String> {
        guard process.threadCount > 0 else { return process.isRestricted ? .denied : .unavailable }
        guard let running = reading.runningThreads.value else { return .value(String(process.threadCount)) }
        return .value("\(process.threadCount) · \(running) running")
    }

    /// Since it started, and per second since the last reading once there is one.
    private func counted(_ total: ProcessField<UInt64>, _ rate: ProcessField<Double>) -> ProcessField<String> {
        total.map { count in
            rate.value.map { "\(Format.count(count)) · \(Format.countRate($0))" } ?? Format.count(count)
        }
    }

    /// The top classes; one under half a percent would read 0%.
    private static func qosText(_ shares: [QoSShare]) -> String {
        let shown = shares.filter { $0.fraction >= 0.005 }.prefix(3)
        guard !shown.isEmpty else { return "No CPU time yet" }
        return shown.map { "\($0.qos.title) \(Format.percent($0.fraction))" }.joined(separator: ", ")
    }

    // MARK: Explanations

    private static let peakHelp = "Peak footprint: the most memory footprint this process has had since it started. "
        + "Well above its footprint now, it once needed far more, and may again."
    private static let faultsHelp = "Page faults: times it touched memory not yet mapped in for it, since it started and per second. "
        + "Most are met from RAM at once; a high rate means it's taking in new memory busily."
    private static let pageInsHelp = "Page-ins: page faults that had to read from disk, from a file it maps (its own code "
        + "included) or from swap. A steady rate means it's waiting on the disk."
    private static let copyOnWriteHelp = "Copy-on-write faults: writes to a page it shared with another process, such as the one "
        + "that started it, which then became its own copy."
    private static let niceHelp = "Nice: from −20 to 20, how much it gives way to other processes. The higher, the less CPU it "
        + "gets when others want it. Set Priority in the table's context menu changes it."
    private static let basePriorityHelp = "Base priority: where the scheduler starts its threads' priorities, from 0 to 127; "
        + "higher runs first. 31 is the usual. Each thread's own moves around it (see the Threads tab)."
    private static let policyHelp = "Scheduling policy: time sharing, the usual one, lowers a busy thread's priority so others "
        + "get their turn. Fixed policies keep it where it is."
    private static let switchesHelp = "Context switches: times one of its threads left a core for another to run, since it "
        + "started and per second. Many a second, with little CPU, means it wakes often for small jobs."
    private static let qosHelp = "Quality of service: how urgent it said its work was, as shares of all its CPU time. "
        + "The scheduler favours the higher classes, and on Apple silicon runs background work on the efficiency cores."
}

/// Who started the process, one parent at a time from launchd down, each a
/// button that selects it in the table, and the process macOS holds
/// responsible for it when that's another.
struct ProcessAncestryList: View {
    @Environment(AppModel.self) private var model
    var process: ProcessSample
    var onSelect: (ProcessIdentity) -> Void

    var body: some View {
        let ancestry = ProcessAncestry.build(for: process, in: model.snapshot?.processes ?? [process])
        let offset = ancestry.gap == nil ? 0 : 1
        VStack(alignment: .leading, spacing: 4) {
            InspectorHeading("Started by")
            if let gap = ancestry.gap { gapRow(gap) }
            ForEach(Array(ancestry.chain.enumerated()), id: \.element.pid) { index, member in
                row(member, depth: index + offset)
            }
            if process.responsiblePID != process.pid { responsible }
        }
        .font(.callout)
    }

    private func row(_ member: ProcessSample, depth: Int) -> some View {
        let isSelf = member.pid == process.pid
        let name = model.displayName(for: member)
        let label = HStack(spacing: 6) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondaryText)
            }
            Image(nsImage: IconCache.icon(for: member, app: model.regularApps[member.pid]))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name).fontWeight(isSelf ? .semibold : .regular).foregroundStyle(isSelf ? Color.primary : Color.accentColor)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("PID \(String(member.pid))").monospacedDigit().foregroundStyle(.secondaryText)
        }
        // Deep chains stop indenting, so names keep their room in a narrow pane.
        .padding(.leading, CGFloat(min(depth, 5)) * 12)
        .contentShape(Rectangle())
        return Group {
            if isSelf {
                label.accessibilityElement(children: .combine)
            } else {
                Button { onSelect(member.identity) } label: { label }
                    .buttonStyle(.plain)
                    .help("Select \(name) (PID \(String(member.pid))) in the table")
                    .accessibilityLabel("\(name), PID \(String(member.pid))")
            }
        }
    }

    private func gapRow(_ gap: ProcessAncestry.Gap) -> some View {
        let (text, help) = switch gap {
        case let .notListed(pid):
            ("PID \(pid) · not in the list", "Its parent isn't in the process list: it ended, or system processes are hidden.")
        case let .replaced(pid):
            ("PID \(pid) · ended", "Its parent has ended, and macOS has given its PID to a later process.")
        }
        return HStack(spacing: 6) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondaryText).frame(width: 16)
            Text(text).foregroundStyle(.secondaryText)
        }
        .help(help)
    }

    /// The app macOS charges this process to, which may be no ancestor.
    @ViewBuilder private var responsible: some View {
        let pid = process.responsiblePID
        let owner = model.process(pid)
        HStack(spacing: 4) {
            Text("Responsible:").foregroundStyle(.secondaryText)
            if let owner {
                Button(model.displayName(for: owner)) { onSelect(owner.identity) }
                    .buttonStyle(.link)
                    .help("Select \(model.displayName(for: owner)) (PID \(String(pid))) in the table")
                Text("PID \(String(pid))").monospacedDigit().foregroundStyle(.secondaryText)
            } else {
                Text("PID \(String(pid))").monospacedDigit()
            }
        }
        .padding(.top, 2)
        .help("The process macOS holds responsible for this one: privacy permissions are asked for, and kept, in its name.")
    }
}
