import Foundation

/// Columns of the Startup table, with the room each takes and the order
/// they give way in when the table runs short (`ColumnFit`). The raw value
/// is the column's customization ID.
public enum StartupColumn: String, CaseIterable, Sendable {
    case name, kind, source, status, cpu, memory, launches, publisher

    /// Narrowest the column gets: room for its usual values in their short
    /// forms (Kind's "Agent" or "Daemon", Status's "Failed exit 1" without a
    /// PID). Name's is room to read nearly every name whole ("Accessibility
    /// Live Transcription Agent"): the others give way before it goes under
    /// that, so in the narrowest window Source hides rather than names being cut.
    public var minWidth: CGFloat {
        switch self {
        case .name: 250
        case .source: 120
        case .kind: 58
        case .status: 100
        case .cpu: 54
        case .memory: 68
        case .launches: 84
        case .publisher: 72
        }
    }

    /// Short values stop growing here; Name takes the rest.
    public var maxWidth: CGFloat? {
        switch self {
        case .name: nil
        case .source: 200
        case .kind: 110
        case .status: 165
        case .cpu: 76
        case .memory: 90
        case .launches: 150
        case .publisher: 100
        }
    }

    /// When the table runs short of room, columns give way lowest priority
    /// first, so Name and Status keep theirs. Publisher goes first, as
    /// third-party rows keep a mark in Name, so nothing is lost. Source next:
    /// the Source filter and details still give it. Then Launches: its few
    /// values repeat down the table and the details spell them out. Then the
    /// job's memory and its CPU, which most jobs, waiting between runs, leave
    /// blank or near 0%, and which the details give for the one selected.
    /// Kind goes last: whether a job is an agent, in someone's login session,
    /// or a daemon, outside any, says what it is, in one short word.
    public var priority: Int? {
        switch self {
        case .name, .status: nil
        case .publisher: 0
        case .source: 1
        case .launches: 2
        case .memory: 3
        case .cpu: 4
        case .kind: 5
        }
    }

    /// The columns that give way, in the order they go.
    public static var hidingOrder: [Self] {
        allCases.filter { $0.priority != nil }.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
    }
}
