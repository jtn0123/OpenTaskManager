import OTMKit
import SwiftUI

extension AppModel {
    /// The group `root` heads in the process table's `mode`, as it stands in
    /// the latest sample: in Grouped, from the app groups the model keeps
    /// each tick; in Tree, the processes under it. Its members are
    /// processes by PID and start time, so one that has ended, or a later
    /// process given its PID, is never among them.
    func processGroup(_ root: ProcessIdentity, mode: ProcessViewMode) -> ProcessGroup? {
        if mode == .grouped, let row = appGroups.first(where: { $0.process?.identity == root }) {
            return ProcessGroup(node: row, mode: .grouped)
        }
        guard let processes = snapshot?.processes else { return nil }
        return ProcessGroup.find(root, in: processes, mode: mode)
    }
}

/// The inspector's Group tab, offered when the selected row has processes
/// nested under it: the row's process and those under it as a whole. Their
/// CPU over the page's window, their figures added up, and each of them
/// with why it's in the group, a click selecting it in the table. Members
/// and figures come from the latest sample each tick; nothing is read for
/// the members themselves.
struct ProcessGroupView: View {
    @Environment(AppModel.self) private var model
    let root: ProcessIdentity
    let mode: ProcessViewMode
    /// Selects a member in the table.
    var onSelect: (ProcessIdentity) -> Void
    @AppStorage("groupMemberSort") private var sort: GroupMemberSort = .cpu

    var body: some View {
        if let group = model.processGroup(root, mode: mode) {
            let names = names(group)
            VStack(alignment: .leading, spacing: 16) {
                summary(group, rootName: names[group.root.pid] ?? group.root.name)
                cpuGraph(group)
                figures(group.figures)
                members(group, names: names)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Nothing is nested under it any more.")
                .font(.explanation).foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Summary

    private func summary(_ group: ProcessGroup, rootName: String) -> some View {
        let others = group.members.count - 1
        let title: String
        let rule: String
        switch mode {
        case .tree:
            title = others == 1 ? "\(rootName) and the process under it" : "\(rootName) and the \(others) processes under it"
            rule = "The processes it started, and the ones they started, as the Tree view nests them."
        case .grouped, .flat:
            title = others == 1 ? "\(rootName) and its helper" : "\(rootName) and its \(others) helpers"
            rule = "The processes macOS holds \(rootName) responsible for, as the Grouped view nests them."
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(rule).font(.explanation).foregroundStyle(.secondaryText)
        }
    }

    // MARK: CPU

    private func cpuGraph(_ group: ProcessGroup) -> some View {
        let scale = model.cpuScale
        return VStack(alignment: .leading, spacing: 4) {
            GraphPanel(
                title: "CPU, all together",
                trailing: scale.format(group.figures.cpuPercent),
                series: [GraphSeries(values: cpuValues(group).map(scale.value), color: Theme.cpu)],
                height: 80,
                minimumCeiling: scale.relativeToSystem ? 2 : 10,
                axis: { Format.fixed($0, $0 < 10 ? 1 : 0) + "%" },
                capacity: AppModel.processHistoryCapacity - 2
            )
            .help(mode == .grouped
                ? "The group's CPU each moment, as it stood then: a helper that has ended keeps its part of the past."
                : "The CPU of the processes under it now, added up over the window. One that has ended leaves the graph.")
            if mode == .tree {
                Text("Adds up the processes under it now; one that has ended leaves the graph.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
        }
    }

    /// Per-core percent, oldest first. Grouped reads the one history the
    /// model keeps per app group; Tree adds up its members' histories,
    /// aligned on the newest, since the model keeps none for a branch.
    private func cpuValues(_ group: ProcessGroup) -> [Double] {
        if group.mode == .grouped {
            return model.appGroupHistory(root)?.values.map(\.cpuPercent) ?? []
        }
        let histories = group.members.compactMap { model.processHistory[$0.id] }
        var sums = [Double](repeating: 0, count: histories.map(\.count).max() ?? 0)
        for history in histories {
            history.addValues(to: &sums) { $0.cpuPercent }
        }
        return sums
    }

    // MARK: Figures

    private func figures(_ figures: ProcessGroupFigures) -> some View {
        let unread: ProcessField<String> = figures.isDiskRead ? .unavailable : .denied
        return VStack(alignment: .leading, spacing: 6) {
            InspectorHeading("Together now")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ProcessFieldRow("CPU", model.cpuScale.format(figures.cpuPercent))
                ProcessFieldRow("Memory", "\(Format.bytes(figures.memory)) summed footprints", help: Self.memoryHelp)
                if model.measuresProcessEnergy != false {
                    ProcessFieldRow("Power", figures.powerWatts.map { .value(Format.watts($0)) } ?? unread,
                                    help: "Power: the members' energy use added up, where macOS measures it")
                }
                if let gpu = figures.gpuFraction {
                    ProcessFieldRow("GPU", Format.percent(gpu, digits: 1), help: "GPU: the members' shares of the GPU's time, added up")
                }
                ProcessFieldRow("Disk read", figures.isDiskRead ? .value(Format.bytesPerSecond(figures.diskReadRate)) : .denied)
                ProcessFieldRow("Disk written", figures.isDiskRead ? .value(Format.bytesPerSecond(figures.diskWriteRate)) : .denied)
                ProcessFieldRow("Threads", String(figures.threads))
                ProcessFieldRow("Processes", String(figures.processCount))
            }
            Text("Memory they share can count in more than one footprint, so the sum can be more than they use together.")
                .font(.explanation).foregroundStyle(.secondaryText)
            if figures.restrictedCount > 0 {
                Text(figures.restrictedCount == 1
                    ? "One of them is another user's or the system's: macOS shows only its CPU and memory, so its disk, GPU and "
                    + "power aren't in the sums."
                    : "\(figures.restrictedCount) of them are other users' or the system's: macOS shows only their CPU and memory, "
                    + "so their disk, GPU and power aren't in the sums.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
        }
    }

    private static let memoryHelp = "Memory: each member's footprint, as in the Memory column, added up. Memory two of them "
        + "share, such as a graphics buffer, can count in both, so the sum can be more than they use together. For "
        + "another user's or a system process, its resident size stands in."

    // MARK: Members

    private func members(_ group: ProcessGroup, names: [Int32: String]) -> some View {
        let rootName = names[group.root.pid] ?? group.root.name
        let sorted = group.members(sortedBy: sort.key, ascending: sort.ascending, cpuStep: model.cpuScale.shownStep)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InspectorHeading("Processes")
                Spacer(minLength: 4)
                sortMenu
            }
            VStack(alignment: .leading, spacing: 0) {
                GroupMemberRow.header
                Divider()
                // Lazy: a branch in Tree can hold hundreds.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { member in
                        let name = names[member.process.pid] ?? member.process.name
                        let reason = Self.reason(member, rootName: rootName, names: names)
                        let row = GroupMemberRow(
                            name: name, pid: member.process.pid, isRoot: member.reason == .root,
                            icon: IconCache.icon(for: member.process, app: model.regularApps[member.process.pid]),
                            cpu: model.cpuScale.format(member.process.cpuPercent),
                            memory: Format.bytes(member.process.memory),
                            reason: reason.text, reasonHelp: reason.help
                        )
                        if member.reason == .root {
                            row.accessibilityElement(children: .combine)
                        } else {
                            Button { onSelect(member.id) } label: { row }
                                .buttonStyle(.plain)
                                .help("Select \(name) (PID \(String(member.process.pid))) in the table")
                                .accessibilityLabel("\(name), PID \(String(member.process.pid)), \(reason.text)")
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(GroupMemberSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Sort: \(sort.title)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.callout)
        .help("Sort the processes: busiest first by CPU or memory, or by name or PID")
    }

    /// Each member's name as the table shows it.
    private func names(_ group: ProcessGroup) -> [Int32: String] {
        Dictionary(group.members.map { ($0.process.pid, model.displayName(for: $0.process)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Why `member` is in the group, short for its row and in full for its tooltip.
    static func reason(_ member: ProcessGroupMember, rootName: String, names: [Int32: String]) -> (text: String, help: String) {
        func named(_ pid: Int32) -> String { names[pid] ?? "PID \(pid)" }
        switch member.reason {
        case .root:
            return ("heads the group", "The process the table's row is for; the others are nested under it.")
        case .responsible:
            return ("\(rootName) is responsible for it",
                    "macOS holds \(rootName) responsible for it: privacy permissions are asked for, and kept, in its name. "
                        + "The Grouped view nests a process under the one responsible for it.")
        case let .responsibleThrough(pid):
            return ("\(named(pid)) is responsible for it",
                    "macOS holds \(named(pid)) (PID \(pid)) responsible for it, and \(rootName) for that one, so the "
                        + "Grouped view nests both under \(rootName).")
        case .child:
            return ("started by \(rootName)", "\(rootName) started it, so the Tree view nests it there.")
        case let .startedBy(pid):
            return ("started by \(named(pid))", "\(named(pid)) (PID \(pid)) started it, and is itself under \(rootName) in the Tree view.")
        }
    }
}

/// How the Group tab orders its processes.
enum GroupMemberSort: String, CaseIterable {
    case cpu, memory, name, pid

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .name: "Name"
        case .pid: "PID"
        }
    }

    var key: ProcessSortKey {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .name: .name
        case .pid: .pid
        }
    }

    /// Busiest first; names and PIDs from the start.
    var ascending: Bool { self == .name || self == .pid }
}

/// A member of the group: its icon and name in the one flexible column,
/// then its CPU and footprint, and under them its PID and why it's in the
/// group. The process the row is for reads in bold; the others are links
/// to their own rows.
private struct GroupMemberRow: View, Equatable {
    var name: String
    var pid: Int32
    var isRoot: Bool
    var icon: NSImage
    var cpu: String
    var memory: String
    var reason: String
    var reasonHelp: String

    static let spacing: CGFloat = 8
    /// "100.0%" in the table's type.
    static let cpuWidth: CGFloat = 46
    /// "1023.9 MB".
    static let memoryWidth: CGFloat = 66

    static var header: some View {
        HStack(spacing: spacing) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                .help("Each process's name over its PID and why it's in the group. Click one to select it in the table.")
            Text("CPU").frame(width: cpuWidth, alignment: .trailing)
                .help("Each process's CPU now, on the page's scale")
            Text("Memory").frame(width: memoryWidth, alignment: .trailing)
                .help("Each process's footprint, as in the table's Memory column")
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
        .padding(.bottom, 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                HStack(spacing: 5) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    Text(name)
                        .fontWeight(isRoot ? .semibold : .regular)
                        .foregroundStyle(isRoot ? Color.primary : Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(cpu).frame(width: Self.cpuWidth, alignment: .trailing)
                Text(memory).frame(width: Self.memoryWidth, alignment: .trailing)
            }
            Text("PID \(String(pid)) · \(reason)")
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 19)
                .help(reasonHelp)
        }
        .font(.tableText)
        .monospacedDigit()
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
