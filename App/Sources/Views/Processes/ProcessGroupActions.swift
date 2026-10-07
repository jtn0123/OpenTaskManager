import OTMKit
import SwiftUI

extension AppModel {
    /// Ends the processes the user confirmed, each checked against the
    /// process holding its PID just before (`ProcessGroupEnding`), so one
    /// that has ended, or whose PID macOS has given to a later process, is
    /// left alone. Apps are asked to quit as their Quit command does, the
    /// rest sent SIGTERM; `force` sends SIGKILL to all. Returns those left
    /// alone.
    func end(_ targets: [ProcessIdentity], force: Bool) -> [ProcessIdentity] {
        let checked = ProcessGroupEnding.revalidate(targets) { ProcessDetailReader.identity(of: $0) }
        let pids = checked.live.map(\.pid)
        if force { forceQuit(pids) } else { endTask(pids) }
        return checked.gone
    }
}

/// The Group tab's footer: End All and Force Quit All. Each first lists
/// exactly whom it will end, by name and PID, as the group stands when it's
/// clicked; a process that joins the group afterwards isn't added.
struct ProcessGroupActions: View {
    @Environment(AppModel.self) private var model
    let root: ProcessIdentity
    let mode: ProcessViewMode
    /// The root is one of your own processes. Another user's or the
    /// system's group (launchd's whole branch in Tree) isn't ended from here.
    var canEnd: Bool
    @State private var request: GroupEndRequest?
    /// What the last End All did, until another process is inspected.
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let outcome {
                Text(outcome).font(.explanation).foregroundStyle(.secondaryText)
            }
            HStack {
                Button("End All…") { prepare(force: false) }
                    .buttonStyle(.borderedProminent)
                    .help(canEnd ? "End All: list every process in the group, then ask each to quit, so it can save its work first"
                        : Self.cantEndHelp)
                Spacer()
                // Kept apart from End All, as Force Quit is from End Task.
                Button(role: .destructive) {
                    prepare(force: true)
                } label: {
                    Label("Force Quit All…", systemImage: "xmark.octagon")
                }
                .foregroundStyle(canEnd ? .red : .secondary)
                .help(canEnd ? "Force Quit All: list every process in the group, then stop each at once, without letting it save"
                    : Self.cantEndHelp)
            }
            .disabled(!canEnd)
        }
        .sheet(item: $request) { request in
            GroupEndSheet(request: request) { confirm(request) }
        }
        .onChange(of: root) { outcome = nil }
    }

    private static let cantEndHelp = "Its process is the system's or another user's, so its group isn't ended from here; "
        + "End Task in each one's inspector can still ask for an administrator"

    /// The group as it stands now, in the order it would be ended.
    private func prepare(force: Bool) {
        guard let group = model.processGroup(root, mode: mode) else { return }
        let plan = group.endingPlan(ownPID: getpid())
        func target(_ member: ProcessGroupMember) -> GroupEndRequest.Target {
            let process = member.process
            let app = model.regularApps[process.pid]
            return GroupEndRequest.Target(identity: member.id, name: model.displayName(for: process),
                                          icon: IconCache.icon(for: process, app: app), isApp: app != nil,
                                          isRestricted: process.isRestricted)
        }
        outcome = nil
        request = GroupEndRequest(force: force, rootName: model.displayName(for: group.root),
                                  targets: plan.targets.map(target), leftAlone: plan.leftAlone.map(target))
    }

    private func confirm(_ request: GroupEndRequest) {
        self.request = nil
        guard !request.targets.isEmpty else { return }
        let gone = model.end(request.targets.map(\.identity), force: request.force)
        let reached = request.targets.count - gone.count
        let processes = reached == 1 ? "1 process" : "\(reached) processes"
        var text = request.force ? "Force quit \(processes)." : "Asked \(processes) to quit."
        if !gone.isEmpty {
            text += gone.count == 1 ? " 1 had already ended, so it was left alone."
                : " \(gone.count) had already ended, so they were left alone."
        }
        outcome = text
    }
}

/// The processes End All or Force Quit All will end, fixed when the
/// button was clicked.
struct GroupEndRequest: Identifiable {
    struct Target: Identifiable {
        var identity: ProcessIdentity
        var name: String
        var icon: NSImage
        var isApp: Bool
        var isRestricted: Bool

        var id: ProcessIdentity { identity }
    }

    let id = UUID()
    var force: Bool
    var rootName: String
    /// In the order they're ended: the root last.
    var targets: [Target]
    /// Other users' and system processes, and this app.
    var leftAlone: [Target]
}

/// The confirmation: every target by name and PID, and what each is sent.
private struct GroupEndSheet: View {
    let request: GroupEndRequest
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let count = request.targets.count
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if count > 0 {
                Text(request.force
                    ? "Each stops at once (SIGKILL), and any unsaved work in it is lost."
                    : "Each is asked to quit: apps as their Quit command does, so they can save first, and the others with SIGTERM.")
                    .font(.explanation)
                list(request.targets)
                Text("They go in this order, \(request.rootName) last. Each is checked again just before: one that has "
                    + "ended, or whose PID now belongs to another process, is left alone, and a process that joins the "
                    + "group after now isn't included.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
            if !request.leftAlone.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(count > 0 ? "Left alone:" : "Nothing here can be ended from this list:").font(.explanation)
                    list(request.leftAlone, maxHeight: 90)
                    Text("Other users' and system processes need an administrator; End Task in each one's inspector can ask. "
                        + "OpenTaskManager doesn't end itself.")
                        .font(.explanation).foregroundStyle(.secondaryText)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if count > 0 {
                    if request.force {
                        Button(count == 1 ? "Force Quit 1 Process" : "Force Quit \(count) Processes", role: .destructive, action: onConfirm)
                    } else {
                        Button(count == 1 ? "End 1 Process" : "End \(count) Processes", action: onConfirm)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var title: String {
        let count = request.targets.count
        guard count > 0 else { return "No processes to end" }
        if count == 1, let only = request.targets.first {
            return request.force ? "Force quit \(only.name)?" : "End \(only.name)?"
        }
        return request.force ? "Force quit these \(count) processes?" : "End these \(count) processes?"
    }

    private func list(_ targets: [GroupEndRequest.Target], maxHeight: CGFloat = 220) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(targets) { target in
                    HStack(spacing: 6) {
                        Image(nsImage: target.icon).resizable().frame(width: 16, height: 16)
                        Text(target.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("PID \(String(target.identity.pid))").monospacedDigit().foregroundStyle(.secondaryText)
                        Text(signal(for: target)).foregroundStyle(.secondaryText)
                            .frame(width: 92, alignment: .trailing)
                    }
                    .font(.tableText)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.03), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }

    /// What `target` is sent, or why it isn't.
    private func signal(for target: GroupEndRequest.Target) -> String {
        if target.isRestricted { return "not yours" }
        if request.leftAlone.contains(where: { $0.id == target.id }) { return "this app" }
        if request.force { return "SIGKILL" }
        return target.isApp ? "asked to quit" : "SIGTERM"
    }
}
