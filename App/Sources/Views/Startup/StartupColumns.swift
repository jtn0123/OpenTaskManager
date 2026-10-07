import AppKit
import OTMKit

/// Columns of the Startup table. The raw value is the column's customization ID.
enum StartupColumn: String, FittingColumn {
    case name, kind, status, cpu, memory, launches, publisher

    /// Narrowest the column gets: room for its usual values in their short
    /// forms (Kind's "Agent" or "Daemon", Status without its PID). Name's is
    /// room to read nearly every name whole ("Accessibility Live
    /// Transcription Agent"): the others give way before it goes under that,
    /// so in the narrowest window Launches hides rather than names being cut.
    var minWidth: CGFloat {
        switch self {
        case .name: 250
        case .kind: 58
        case .status: 100
        case .cpu: 54
        case .memory: 68
        case .launches: 84
        case .publisher: 72
        }
    }

    /// Short values stop growing here; Name takes the rest.
    var maxWidth: CGFloat? {
        switch self {
        case .name: nil
        case .kind: 110
        case .status: 165
        case .cpu: 76
        case .memory: 90
        case .launches: 150
        case .publisher: 100
        }
    }

    /// When the table runs short of room, columns give way lowest priority
    /// first, so Name and Status keep theirs. Launches goes first: its few
    /// values repeat down the table and the details spell them out. Publisher
    /// next, as third-party rows keep a mark in Name; then Kind, which the
    /// Agents and Daemons filters cover; and the job's memory before its CPU.
    var priority: Int? {
        switch self {
        case .name, .status: nil
        case .cpu: 5
        case .memory: 4
        case .kind: 3
        case .publisher: 2
        case .launches: 1
        }
    }
}
