import OTMKit
import SwiftUI

/// The inspector for one startup item: what it runs, what starts it, how
/// launchd is treating it now, and where its property list lives.
struct StartupItemDetail: View {
    var item: LaunchItem
    /// Changes when the page rescans, so launchd's view is read again.
    var refreshID: Date?
    /// Disables or enables the item, for third-party agents.
    var toggle: () -> Void
    /// Starts, restarts or stops the job, for third-party agents.
    var control: (LaunchControl.Action) -> Void
    var showProcess: (Int32) -> Void

    /// launchd's view of the job, read when the item is shown and after a
    /// rescan, never per tick. Nil while reading, or when it isn't loaded.
    @State private var service: LaunchServiceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    if let note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
                    program
                    launches
                    labelled("Property list", item.plistPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if LaunchControl.restriction(for: item) == nil, let service {
                serviceControls(service)
            }
            if LaunchControl.restriction(for: item) == nil {
                HStack(alignment: .firstTextBaseline) {
                    Button(item.isDisabled ? "Enable" : "Disable…", action: toggle)
                    Text(item.isDisabled ? "Loads it now and at every login." : "Stops it now and at every login, for your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if item.publisher == .thirdParty, let reason = LaunchControl.restriction(for: item) {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { StartupActions.reveal(item) }
                Button("Show plist") { StartupActions.openPlist(item) }
                Spacer()
            }
        }
        .padding(12)
        .task(id: ServiceRead(label: item.label, scope: item.scope, refreshID: refreshID)) {
            let (label, scope) = (item.label, item.scope)
            service = await Task.detached(priority: .userInitiated) { Launchctl.service(label, scope: scope) }.value
        }
    }

    private struct ServiceRead: Equatable {
        var label: String
        var scope: LaunchItemScope
        var refreshID: Date?
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forBundle: item.appBundlePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(2)
                Text(item.label)
                    .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.label)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                LaunchStateLabel(state: item.state)
            }
            .font(.callout)
            if let disabledBy {
                FactRow(label: "Disabled by", value: disabledBy)
            }
            if let service { serviceRows(service) }
            FactRow(label: "Kind", value: item.scope.title)
            FactRow(label: "Publisher", value: item.publisher.title)
            FactRow(label: "Last exit", value: lastExit)
            if let modified = item.modified {
                FactRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder private var program: some View {
        if let path = item.program {
            labelled("Program", path)
        } else if !item.isUnreadable {
            labelled("Program", "None: the property list names no program", isCode: false)
        }
        let arguments = item.arguments.first == item.program ? Array(item.arguments.dropFirst()) : item.arguments
        if !arguments.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Arguments").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                    CopyableText(value: argument).font(.subheadline)
                }
            }
        }
    }

    private var launches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launches").font(.subheadline).foregroundStyle(.secondary)
            if item.isUnreadable {
                Text("Unknown: the property list can't be read").font(.callout)
            } else {
                ForEach(item.triggers.details(for: item.scope), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondary)
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func serviceRows(_ service: LaunchServiceInfo) -> some View {
        if let pid = service.pid {
            // The status row above already shows the PID.
            GridRow {
                Text("Process").foregroundStyle(.secondary)
                Button("Show in Processes") { showProcess(pid) }
                    .buttonStyle(.link)
                    .help("Select PID \(String(pid)) on the Processes page")
            }
            .font(.callout)
        }
        if let runs = service.runs {
            FactRow(label: "Runs", value: "\(runs) since \(item.scope == .daemon ? "startup" : "login")")
        }
        if service.isRunning, let reason = service.startReason {
            GridRow {
                Text("Started by").foregroundStyle(.secondary)
                Text(LaunchServiceInfo.describe(startReason: reason))
                    .help("launchd's reason: \(reason)")
            }
            .font(.callout)
        }
        if let priority = service.priority {
            GridRow {
                Text("Priority").foregroundStyle(.secondary)
                Text(priority.title).help(priority.explanation)
            }
            .font(.callout)
        }
    }

    /// Start, restart and stop, for a loaded job this app may control.
    private func serviceControls(_ service: LaunchServiceInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if service.isRunning {
                Button("Restart") { control(.restart) }
                    .help("Stop the job and start it again")
                Button("Stop") { control(.stop) }
                    .help(stopHelp)
            } else {
                Button("Start Now") { control(.start) }
                    .help("Run the job now, whatever usually launches it")
            }
            Text(service.isRunning ? afterStop : "Runs it once, now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Text

    private var afterStop: String {
        switch item.triggers.keepAlive {
        case .always: "launchd restarts it after a stop."
        case .conditional: "launchd may restart it after a stop."
        case .never: "A stop lasts until it's next launched."
        }
    }

    private var stopHelp: String {
        switch item.triggers.keepAlive {
        case .always: "Ask the job to quit. launchd keeps it alive, so it starts again straight away."
        case .conditional: "Ask the job to quit. launchd may start it again, depending on its keep-alive conditions."
        case .never: "Ask the job to quit. It starts again the next time something launches it."
        }
    }

    private var lastExit: String {
        let reason = service?.lastExitReason.map(LaunchServiceInfo.describe(exitReason:))
        if let exit = item.job?.lastExit { return [exit.description, reason].compactMap(\.self).joined(separator: " · ") }
        return item.job == nil ? "—" : "Hasn't exited"
    }

    private var disabledBy: String? {
        switch (item.disabledOverride, item.disabledInPlist) {
        case (true?, _): "launchctl disable"
        case (nil, true): "Its Disabled key"
        default: nil
        }
    }

    /// Why an item won't load, or that an override beats its plist.
    private var note: String? {
        if item.isMissingLabel { return "This property list has no Label, so launchd ignores it." }
        if item.isUnreadable { return "This property list can't be read, so its settings are unknown." }
        if item.disabledOverride == false, item.disabledInPlist {
            return "Enabled with launchctl, which overrides the Disabled key in its property list."
        }
        return nil
    }

    private func labelled(_ label: String, _ value: String, isCode: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            CopyableText(value: value, monospaced: isCode).font(.subheadline)
        }
    }
}
