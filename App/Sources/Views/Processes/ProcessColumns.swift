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

    /// The column's line in the Columns menus, saying so when it's on but
    /// hidden for now because the table is too narrow.
    func menuTitle(hiddenToFit: Bool) -> String {
        hiddenToFit ? "\(title) (hidden to fit)" : title
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

/// The columns switched off in the Columns menu, saved as "kind,threads".
struct HiddenProcessColumns: RawRepresentable, Equatable {
    var columns: Set<ProcessColumn>

    static let defaults = HiddenProcessColumns(columns: Set(ProcessColumn.allCases.filter(\.hiddenByDefault)))

    init(columns: Set<ProcessColumn>) {
        self.columns = columns
    }

    init?(rawValue: String) {
        columns = Set(rawValue.split(separator: ",").compactMap { ProcessColumn(rawValue: String($0)) })
    }

    var rawValue: String {
        columns.map(\.rawValue).sorted().joined(separator: ",")
    }

    func contains(_ column: ProcessColumn) -> Bool {
        columns.contains(column)
    }

    mutating func toggle(_ column: ProcessColumn) {
        guard column != .name else { return }
        if columns.remove(column) == nil { columns.insert(column) }
    }
}
