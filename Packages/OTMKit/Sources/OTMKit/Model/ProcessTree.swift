import Foundation

public enum ProcessViewMode: String, CaseIterable, Sendable, Codable {
    /// Apps, background processes and system processes, with helpers nested
    /// under the app responsible for them.
    case grouped
    /// Parent/child hierarchy.
    case tree
    /// One row per process.
    case flat
}

public enum ProcessSection: Int, CaseIterable, Sendable {
    case apps = 1, background, system

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .background: "Background processes"
        case .system: "System processes"
        }
    }
}

public struct ProcessTotals: Sendable, Hashable {
    public var cpuPercent: Double = 0
    public var memory: UInt64 = 0
    /// Summed over the processes with a power reading; see `isPowerMeasured`.
    public var powerWatts: Double = 0
    /// Whether any process counted here had a power reading. When none did
    /// (restricted processes, or a Mac that doesn't count energy per process),
    /// `powerWatts` is 0 for want of data, not a measured 0 W.
    public var isPowerMeasured = false
    public var gpuFraction: Double = 0
    public var diskRate: Double = 0
    public var threads: Int = 0
    public var processCount: Int = 0

    public init() {}

    public init(_ process: ProcessSample) {
        cpuPercent = process.cpuPercent
        memory = process.memory
        powerWatts = process.powerWatts ?? 0
        isPowerMeasured = process.powerWatts != nil
        gpuFraction = process.gpuFraction ?? 0
        diskRate = process.diskReadRate + process.diskWriteRate
        threads = process.threadCount
        processCount = 1
    }

    mutating func add(_ other: ProcessTotals) {
        cpuPercent += other.cpuPercent
        memory += other.memory
        powerWatts += other.powerWatts
        isPowerMeasured = isPowerMeasured || other.isPowerMeasured
        gpuFraction += other.gpuFraction
        diskRate += other.diskRate
        threads += other.threads
        processCount += other.processCount
    }
}

public struct ProcessNode: Sendable, Identifiable {
    /// The PID for process rows; negative section numbers for section rows.
    public let id: Int64
    public let section: ProcessSection?
    public let process: ProcessSample?
    public var children: [ProcessNode]
    /// This row plus everything nested under it.
    public var totals: ProcessTotals

    static func section(_ section: ProcessSection, children: [ProcessNode]) -> ProcessNode {
        var totals = ProcessTotals()
        children.forEach { totals.add($0.totals) }
        return ProcessNode(id: -Int64(section.rawValue), section: section, process: nil, children: children, totals: totals)
    }

    static func process(_ process: ProcessSample, children: [ProcessNode] = []) -> ProcessNode {
        var totals = ProcessTotals(process)
        children.forEach { totals.add($0.totals) }
        return ProcessNode(id: Int64(process.pid), section: nil, process: process, children: children, totals: totals)
    }
}

public enum ProcessSortKey: String, Sendable, CaseIterable {
    case name, pid, cpu, memory, power, gpu, disk, threads, user, topTier, wakeups
}

public enum ProcessTreeBuilder {
    public static func build(
        _ processes: [ProcessSample],
        mode: ProcessViewMode,
        appPIDs: Set<Int32>,
        currentUID: UInt32 = getuid(),
        filter: String = ""
    ) -> [ProcessNode] {
        let nodes: [ProcessNode] = switch mode {
        case .flat: processes.map { .process($0) }
        case .tree: tree(processes)
        case .grouped: grouped(processes, appPIDs: appPIDs, currentUID: currentUID)
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nodes : self.filter(nodes, query: query)
    }

    /// The row for `pid` among `nodes` and everything nested under them, as
    /// the table shows it: in grouped and tree modes, its totals include the
    /// processes nested under it. Stops at the first match.
    public static func node(for pid: Int32, in nodes: [ProcessNode]) -> ProcessNode? {
        for node in nodes {
            if node.process?.pid == pid { return node }
            if let found = self.node(for: pid, in: node.children) { return found }
        }
        return nil
    }

    // MARK: Grouped

    static func grouped(_ processes: [ProcessSample], appPIDs: Set<Int32>, currentUID: UInt32) -> [ProcessNode] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        // Follow responsibility up to the process that owns the group. Chains
        // are short in practice; the hop limit guards against cycles.
        func groupRoot(of process: ProcessSample) -> Int32 {
            var current = process
            for _ in 0..<4 {
                let owner = current.responsiblePID
                guard owner != current.pid, let next = byPID[owner] else { break }
                current = next
            }
            return current.pid
        }

        var members: [Int32: [ProcessSample]] = [:]
        for process in processes {
            let root = groupRoot(of: process)
            if root != process.pid { members[root, default: []].append(process) }
        }

        var sections: [ProcessSection: [ProcessNode]] = [:]
        for process in processes where groupRoot(of: process) == process.pid {
            let children = (members[process.pid] ?? []).map { ProcessNode.process($0) }
            let section: ProcessSection = if appPIDs.contains(process.pid) {
                .apps
            } else if process.uid == currentUID {
                .background
            } else {
                .system
            }
            sections[section, default: []].append(.process(process, children: children))
        }

        return ProcessSection.allCases.compactMap { section in
            guard let children = sections[section], !children.isEmpty else { return nil }
            return .section(section, children: children)
        }
    }

    // MARK: Tree

    static func tree(_ processes: [ProcessSample]) -> [ProcessNode] {
        let present = Set(processes.map(\.pid))
        let children = Dictionary(grouping: processes.filter { $0.parentPID != $0.pid && present.contains($0.parentPID) }, by: \.parentPID)

        func node(for process: ProcessSample, depth: Int) -> ProcessNode {
            // Depth guard: PID reuse can, in theory, produce a cycle.
            let kids = depth > 64 ? [] : (children[process.pid] ?? []).map { node(for: $0, depth: depth + 1) }
            return .process(process, children: kids)
        }

        return processes
            .filter { $0.parentPID == $0.pid || !present.contains($0.parentPID) }
            .map { node(for: $0, depth: 0) }
    }

    // MARK: Filtering

    static func filter(_ nodes: [ProcessNode], query: String) -> [ProcessNode] {
        nodes.compactMap { node in
            if let process = node.process, matches(process, query) { return node }
            let kept = filter(node.children, query: query)
            guard !kept.isEmpty else { return nil }
            if let section = node.section { return .section(section, children: kept) }
            if let process = node.process { return .process(process, children: kept) }
            return nil
        }
    }

    static func matches(_ process: ProcessSample, _ query: String) -> Bool {
        if let pid = Int32(query) { return process.pid == pid }
        return process.name.localizedCaseInsensitiveContains(query)
            || process.userName.localizedCaseInsensitiveContains(query)
            || (process.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
    }

    // MARK: Sorting

    /// Sorts siblings at every level. Sections keep their fixed order; rows
    /// inside them sort by their group totals so busy apps rise together.
    public static func sort(_ nodes: [ProcessNode], by key: ProcessSortKey, ascending: Bool) -> [ProcessNode] {
        let sortedChildren = nodes.map { node -> ProcessNode in
            var node = node
            node.children = sort(node.children, by: key, ascending: ascending)
            return node
        }
        guard sortedChildren.allSatisfy({ $0.section == nil }) else { return sortedChildren }
        return sortedChildren.sorted { lhs, rhs in
            let order = compare(lhs, rhs, by: key)
            if order == .orderedSame { return lhs.id < rhs.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ lhs: ProcessNode, _ rhs: ProcessNode, by key: ProcessSortKey) -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        let a = lhs.process, b = rhs.process
        switch key {
        case .name: return (a?.name ?? "").localizedCaseInsensitiveCompare(b?.name ?? "")
        case .pid: return order(lhs.id, rhs.id)
        case .cpu: return order(lhs.totals.cpuPercent, rhs.totals.cpuPercent)
        case .memory: return order(lhs.totals.memory, rhs.totals.memory)
        case .power: return order(lhs.totals.powerWatts, rhs.totals.powerWatts)
        case .gpu: return order(lhs.totals.gpuFraction, rhs.totals.gpuFraction)
        case .disk: return order(lhs.totals.diskRate, rhs.totals.diskRate)
        case .threads: return order(lhs.totals.threads, rhs.totals.threads)
        case .user: return (a?.userName ?? "").localizedCaseInsensitiveCompare(b?.userName ?? "")
        case .topTier: return order(a?.topTierShare ?? -1, b?.topTierShare ?? -1)
        case .wakeups: return order(a?.wakeupsPerSecond ?? -1, b?.wakeupsPerSecond ?? -1)
        }
    }
}
