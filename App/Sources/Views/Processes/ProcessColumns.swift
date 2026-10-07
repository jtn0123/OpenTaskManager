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

    /// Narrowest a column can be dragged: its header's name and total stay whole.
    var minWidth: CGFloat {
        switch self {
        case .name: 150
        case .disk: 76
        case .user: 56
        default: 48
        }
    }

    /// Off until switched on from the Columns menu. Threads is here too so
    /// the rest fit beside the inspector in the default window.
    var hiddenByDefault: Bool {
        self == .threads || self == .wakeups || self == .kind || self == .topTier
    }

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

    /// Width the table needs for the default columns, Name at its narrowest,
    /// until the table measures its own. The 4 is the table's edge insets.
    static let defaultTableMinimum: CGFloat = allCases.filter { !$0.hiddenByDefault }.reduce(4) { width, column in
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
