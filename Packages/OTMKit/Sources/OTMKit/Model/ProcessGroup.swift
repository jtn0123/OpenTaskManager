import Foundation

/// Why a process is in the group the process table nests under a row, by
/// the rule `ProcessTreeBuilder` nested it with.
public enum ProcessGroupReason: Sendable, Hashable {
    /// The process the row is for, which heads the group.
    case root
    /// Grouped: macOS holds the root responsible for it.
    case responsible
    /// Grouped: macOS holds `pid` responsible for it, and the root for
    /// that one, or for the one responsible for it (a helper's helper).
    case responsibleThrough(pid: Int32)
    /// Tree: the root started it.
    case child
    /// Tree: `pid`, itself under the root, started it.
    case startedBy(pid: Int32)

    /// The member that brought this one into the group: the one macOS
    /// holds responsible for it, or its parent. nil for the root.
    public var via: Int32? {
        switch self {
        case .root, .responsible, .child: nil
        case let .responsibleThrough(pid), let .startedBy(pid): pid
        }
    }
}

/// A process in a group, and why it's there.
public struct ProcessGroupMember: Sendable, Hashable, Identifiable {
    public let process: ProcessSample
    public let reason: ProcessGroupReason
    /// Steps from the root: 0 for the root, 1 for what it's responsible for
    /// or started, 2 for theirs.
    public let depth: Int

    public var id: ProcessIdentity { process.identity }
}

/// A row of the process table with processes nested under it, taken as a
/// whole: the process it's for, every process under it, and their figures
/// added up. Members are processes by PID and start time, taken from one
/// sample, so a helper that has ended, or a later process given its PID,
/// is never listed.
public struct ProcessGroup: Sendable, Hashable {
    public let mode: ProcessViewMode
    /// The root first, then the rest as the table nests them: in Tree, each
    /// process before those it started.
    public let members: [ProcessGroupMember]
    public let figures: ProcessGroupFigures

    public var root: ProcessSample { members[0].process }

    /// A row from `ProcessTreeBuilder.build` in `mode`, with everything
    /// under it. nil for a section's row, or in Flat, which nests nothing.
    public init?(node: ProcessNode, mode: ProcessViewMode) {
        guard let root = node.process, mode != .flat else { return nil }
        var members = [ProcessGroupMember(process: root, reason: .root, depth: 0)]
        if mode == .grouped {
            members += Self.responsibilityMembers(node.children, root: root)
        } else {
            Self.descendants(node.children, of: root, root: root, depth: 1, into: &members)
        }
        self.mode = mode
        self.members = members
        figures = ProcessGroupFigures(members.lazy.map(\.process))
    }

    /// The group `root` heads in `mode` among `processes`, as the table
    /// nests it without a search. nil once `root` has ended, when another
    /// row holds it, or in Flat.
    public static func find(_ root: ProcessIdentity, in processes: [ProcessSample], mode: ProcessViewMode) -> ProcessGroup? {
        switch mode {
        case .flat:
            return nil
        case .tree:
            return ProcessTreeBuilder.subtree(of: root, in: processes).flatMap { ProcessGroup(node: $0, mode: .tree) }
        case .grouped:
            // Which apps there are only picks the section, not the groups.
            let rows = ProcessTreeBuilder.grouped(processes, appPIDs: [], currentUID: 0).flatMap(\.children)
            return rows.first { $0.process?.identity == root }.flatMap { ProcessGroup(node: $0, mode: .grouped) }
        }
    }

    /// The members ordered as the process table would order these rows.
    public func members(sortedBy key: ProcessSortKey, ascending: Bool, cpuStep: Double = 0) -> [ProcessGroupMember] {
        let byPID = Dictionary(members.map { ($0.process.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return ProcessTreeBuilder.sort(members.map { ProcessNode.process($0.process) }, by: key, ascending: ascending, cpuStep: cpuStep)
            .compactMap { node in node.process.flatMap { byPID[$0.pid] } }
    }

    /// Whom ending the whole group ends, in order: those furthest from the
    /// root first and the root last, as End Process Tree ends children
    /// before their parents. Left alone: another user's and the system's
    /// processes, which would take an administrator's password per batch,
    /// and `ownPID`, so the app doesn't end itself halfway through. A group
    /// whose root is another user's or the system's (launchd's branch in
    /// Tree) isn't ended at all: it would stay to start its helpers again,
    /// and launchd's would be the whole session.
    public func endingPlan(ownPID: Int32) -> (targets: [ProcessGroupMember], leftAlone: [ProcessGroupMember]) {
        let ordered = members.enumerated()
            .sorted { $0.element.depth != $1.element.depth ? $0.element.depth > $1.element.depth : $0.offset < $1.offset }
            .map(\.element)
        guard !root.isRestricted else { return ([], ordered) }
        let isTarget = { (member: ProcessGroupMember) in !member.process.isRestricted && member.process.pid != ownPID }
        return (ordered.filter(isTarget), ordered.filter { !isTarget($0) })
    }

    /// Grouped nests every process along a chain of responsibility one
    /// level down; the chain's first step says how each got there.
    private static func responsibilityMembers(_ nodes: [ProcessNode], root: ProcessSample) -> [ProcessGroupMember] {
        let byPID = Dictionary(nodes.compactMap { $0.process.map { ($0.pid, $0) } }, uniquingKeysWith: { first, _ in first })
        return nodes.compactMap { node in
            guard let process = node.process else { return nil }
            let owner = process.responsiblePID
            // Steps back to the root, through the group's own members; the
            // builder's hop limit keeps chains short.
            var depth = 1
            var next = owner
            while next != root.pid, depth < 8, let step = byPID[next], step.responsiblePID != step.pid {
                next = step.responsiblePID
                depth += 1
            }
            return ProcessGroupMember(process: process, reason: owner == root.pid ? .responsible : .responsibleThrough(pid: owner),
                                      depth: depth)
        }
    }

    /// Tree nests each process under the one that started it.
    private static func descendants(_ nodes: [ProcessNode], of parent: ProcessSample, root: ProcessSample, depth: Int,
                                    into members: inout [ProcessGroupMember]) {
        for node in nodes {
            guard let process = node.process else { continue }
            members.append(ProcessGroupMember(process: process, reason: parent.pid == root.pid ? .child : .startedBy(pid: parent.pid),
                                              depth: depth))
            descendants(node.children, of: process, root: root, depth: depth + 1, into: &members)
        }
    }
}

/// A group's figures now, added up over its members.
public struct ProcessGroupFigures: Sendable, Hashable {
    /// Activity Monitor-style percent: 100 = one core.
    public var cpuPercent = 0.0
    /// The members' footprints added up (resident size for those macOS
    /// shows only that of). Memory two of them share can count in each.
    public var memory: UInt64 = 0
    /// Bytes per second, over the members macOS reveals them for.
    public var diskReadRate = 0.0
    public var diskWriteRate = 0.0
    public var threads = 0
    public var processCount = 0
    /// Members macOS shows only CPU and memory for (another user's or the
    /// system's): their disk, GPU and power aren't in the sums.
    public var restrictedCount = 0
    /// The members' GPU time over the time that passed, added up; nil when
    /// no member has a GPU reading.
    public var gpuFraction: Double?
    /// Watts; nil when no member has a power reading, which is missing
    /// data rather than a measured 0 W.
    public var powerWatts: Double?

    public init() {}

    public init(_ processes: some Sequence<ProcessSample>) {
        for process in processes {
            cpuPercent += process.cpuPercent
            memory += process.memory
            threads += process.threadCount
            processCount += 1
            if process.isRestricted {
                restrictedCount += 1
            } else {
                diskReadRate += process.diskReadRate
                diskWriteRate += process.diskWriteRate
            }
            if process.gpuTime != nil { gpuFraction = (gpuFraction ?? 0) + (process.gpuFraction ?? 0) }
            if let watts = process.powerWatts { powerWatts = (powerWatts ?? 0) + watts }
        }
    }

    /// Whether disk figures were read for any member.
    public var isDiskRead: Bool { restrictedCount < processCount }
}

/// Ending a group's processes once the user has confirmed the list: each
/// is checked again just before, so one that has ended, or whose PID now
/// belongs to a later process, is left alone, and a process that joined
/// the group after the list was shown isn't touched.
public enum ProcessGroupEnding {
    /// `targets` split into those still running as themselves, in their
    /// order, and those that aren't. `current` gives the process holding a
    /// PID now (`ProcessDetailReader.identity(of:)`), nil when none does.
    public static func revalidate(_ targets: [ProcessIdentity], current: (Int32) -> ProcessIdentity?)
        -> (live: [ProcessIdentity], gone: [ProcessIdentity]) {
        var live: [ProcessIdentity] = []
        var gone: [ProcessIdentity] = []
        var seen: Set<ProcessIdentity> = []
        for target in targets where seen.insert(target).inserted {
            if current(target.pid) == target {
                live.append(target)
            } else {
                gone.append(target)
            }
        }
        return (live, gone)
    }
}
