import AppKit
import OTMKit
import SwiftUI

/// Columns of the process table. The raw value doubles as the column
/// identifier and, where sortable, the `ProcessSortKey`.
enum ProcessColumn: String, CaseIterable {
    case name, pid, cpu, memory, power, gpu, disk, threads, topTier, wakeups, user, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .pid: "PID"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .threads: "Threads"
        case .topTier: "Fast cores"
        case .wakeups: "Wakeups/s"
        case .user: "User"
        case .kind: "Kind"
        }
    }

    /// Starting width: room for the longest usual value ("1023 KB/s",
    /// "100.0%") and for the header's name in bold beside the sort chevron.
    /// Name takes whatever the others leave.
    var width: CGFloat {
        switch self {
        case .name: 240
        case .pid: 54
        case .cpu: 68
        case .memory, .threads: 72
        case .power: 64
        case .gpu: 58
        case .disk: 80
        case .topTier: 70
        case .wakeups: 76
        case .user: 76
        case .kind: 56
        }
    }

    /// Narrowest a column can be dragged: its header's name and total stay
    /// whole. Name's is room for an app's name, icon and child count at the
    /// first level of the outline: columns give way before Name goes below it.
    var minWidth: CGFloat {
        switch self {
        case .name: 220
        case .disk: 76
        case .user: 56
        default: 48
        }
    }

    /// When the table runs short of room, columns give way lowest priority
    /// first (`ColumnFit`), so the ones that say which process a row is and
    /// what it costs stay. Nil for Name, PID, CPU and Memory, which always stay.
    /// User ranks low: on most Macs it says the same thing on every row.
    var priority: Int? {
        switch self {
        case .name, .pid, .cpu, .memory: nil
        case .disk: 8
        case .power: 7
        case .gpu: 6
        case .user: 5
        case .threads: 4
        case .wakeups: 3
        case .topTier: 2
        case .kind: 1
        }
    }

    /// Off until switched on from the Columns menu. Threads is here too so
    /// the rest fit beside the inspector in the default window.
    var hiddenByDefault: Bool {
        self == .threads || self == .wakeups || self == .kind || self == .topTier
    }

    /// The column's line in the Columns menus, saying why it's hidden when
    /// the user didn't hide it: this Mac doesn't report it, or it's on but
    /// hidden for now because the table is too narrow.
    func menuTitle(hiddenToFit: Bool, unreported: Bool = false) -> String {
        if unreported { return "\(title) (not reported on this Mac)" }
        return hiddenToFit ? "\(title) (hidden to fit)" : title
    }

    /// Columns this Mac has no figures for, which start hidden: Power when
    /// it doesn't measure energy per process (a virtual machine), and GPU
    /// when no process has any GPU time (`ProcessGPUReporting`), where every
    /// row would read "—". nil is unknown yet, and counts as reported.
    static func unreported(measuresEnergy: Bool?, reportsGPU: Bool?) -> Set<ProcessColumn> {
        var columns: Set<ProcessColumn> = []
        if measuresEnergy == false { columns.insert(.power) }
        if reportsGPU == false { columns.insert(.gpu) }
        return columns
    }

    /// The header's tooltip, for columns whose name alone doesn't say what they measure.
    var headerHelp: String? {
        switch self {
        case .memory: MemoryMeasure.column
        case .gpu: "GPU: the share of the GPU's time each process used. \"—\" for a process that hasn't used the GPU."
        default: nil
        }
    }

    /// Closes the Columns menus while a column is hidden to fit.
    static let hiddenToFitNote = "Columns hidden to fit come back when there's room"

    var sortKey: ProcessSortKey? {
        switch self {
        case .kind: nil
        default: ProcessSortKey(rawValue: rawValue)
        }
    }

    var isNumeric: Bool {
        self != .name && self != .user && self != .kind
    }

    /// Colour of the meter bar behind busy values, matching the Performance page.
    @MainActor var meterColor: NSColor? {
        switch self {
        case .cpu: Self.colors.cpu
        case .memory: Self.colors.memory
        case .power: Self.colors.power
        case .gpu: Self.colors.gpu
        case .disk: Self.colors.disk
        case .wakeups: Self.colors.wakeups
        default: nil
        }
    }

    /// The meters sit behind the numbers, so they keep the pastel fill shade.
    @MainActor private static let colors = (
        cpu: NSColor(Theme.cpu).fillShade, memory: NSColor(Theme.memory).fillShade, power: NSColor(Theme.power).fillShade,
        gpu: NSColor(Theme.gpu).fillShade, disk: NSColor(Theme.disk).fillShade, wakeups: NSColor(Theme.network).fillShade
    )

    /// Gap between columns, narrower than AppKit's 17 so every default
    /// column fits beside the inspector in the default window.
    static let spacing: CGFloat = 8

    /// Width the table needs for the columns that always stay, Name at its
    /// narrowest, until the table measures its own. The 4 is the table's edge insets.
    static let defaultTableMinimum: CGFloat = allCases.filter { $0.priority == nil }.reduce(4) { width, column in
        width + (column == .name ? column.minWidth : column.width) + spacing
    }
}

/// What the process memory figures measure, for the table's Memory header
/// and the inspector, which shows two of them side by side.
enum MemoryMeasure {
    static let footprint = "Memory footprint: what macOS charges to this process. It counts the memory the process has "
        + "written to, compressed pages included, but not shared libraries or files it can read back from disk. "
        + "The table's Memory column shows it, as Activity Monitor's does."
    static let resident = "Real memory: the pages this process has in RAM right now, shared libraries and mapped files "
        + "included. A page shared with other processes counts in each of them, so it's usually more than the footprint "
        + "and doesn't add up across processes."
    static let restricted = "Resident memory: the pages this process has in RAM, shared ones included. macOS reveals only "
        + "this of other users' and system processes, so the table shows it for them too."
    static let column = "Memory: each process's footprint, what macOS charges to it, as in Activity Monitor. A collapsed "
        + "row adds up the processes under it. System processes show their resident size, the most macOS reveals of them."
}

/// The columns switched off in the Columns menu, and the ones this Mac can't
/// fill that were switched on anyway, saved as "kind,threads,+power".
struct HiddenProcessColumns: RawRepresentable, Equatable {
    var columns: Set<ProcessColumn>
    /// Unreported columns (see `ProcessColumn.unreported`) the user turned
    /// on, to see the dashes. The others stay hidden.
    var shownAnyway: Set<ProcessColumn> = []

    static let defaults = HiddenProcessColumns(columns: Set(ProcessColumn.allCases.filter(\.hiddenByDefault)))

    init(columns: Set<ProcessColumn>) {
        self.columns = columns
    }

    init?(rawValue: String) {
        let entries = rawValue.split(separator: ",")
        columns = Set(entries.compactMap { ProcessColumn(rawValue: String($0)) })
        shownAnyway = Set(entries.compactMap { $0.first == "+" ? ProcessColumn(rawValue: String($0.dropFirst())) : nil })
    }

    var rawValue: String {
        (columns.map(\.rawValue) + shownAnyway.map { "+" + $0.rawValue }).sorted().joined(separator: ",")
    }

    /// Hidden by choice, or because this Mac doesn't report it.
    func hidden(unreported: Set<ProcessColumn>) -> Set<ProcessColumn> {
        columns.union(unreported.subtracting(shownAnyway))
    }

    func isOn(_ column: ProcessColumn, unreported: Set<ProcessColumn>) -> Bool {
        !hidden(unreported: unreported).contains(column)
    }

    /// Switches a column on or off. An unreported column switched off goes
    /// back to hiding by itself, so it shows again on a Mac that reports it.
    mutating func toggle(_ column: ProcessColumn, unreported: Set<ProcessColumn>) {
        guard column != .name else { return }
        if isOn(column, unreported: unreported) {
            if unreported.contains(column) { shownAnyway.remove(column) } else { columns.insert(column) }
        } else {
            columns.remove(column)
            if unreported.contains(column) { shownAnyway.insert(column) }
        }
    }
}
