import OTMKit
import SwiftUI

/// The inspector for one startup item: what it runs, what starts it, how
/// launchd is treating it now, and where its property list lives.
struct StartupItemDetail: View {
    /// For the job's CPU and memory now, which follow the sampling tick.
    let model: AppModel
    var item: LaunchItem
    /// Whether its job looks troubled, from launchd's last exit and the restarts seen.
    var health: LaunchJobHealth
    /// What this session has seen of its job; nil until it's been loaded at a read.
    var record: LaunchJobRecord?
    /// Changes when the page rescans, so launchd's view is read again.
    var refreshID: Date?
    /// Disables or enables the item, for third-party agents.
    var toggle: () -> Void
    /// Starts, restarts or stops the job, for third-party agents.
    var control: (LaunchControl.Action) -> Void
    var showProcess: (Int32) -> Void
    /// Brings the item's row into view in the table.
    var showInList: () -> Void

    /// launchd's view of the job, read when the item is shown, after a
    /// rescan, and when its process or last exit changes, never per tick.
    /// Nil while reading, or when it isn't loaded.
    @State private var service: LaunchServiceInfo?
    /// Folded at first, and left as it is while the selection moves.
    @State private var showsArguments = false
    /// The pane's height, and the pinned top's and footer's as laid out.
    @State private var height: CGFloat?
    @State private var topHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// The item, launchd's view of it in plain words and the action that
    /// fits sit at the top; the lasting change (Disable) and the file itself
    /// stay in a footer; and everything else scrolls between them, in the
    /// pane's only scroll view.
    ///
    /// The pinned top is tall, and a pane's minimum height becomes the
    /// window's: laid out alone it pushed the status bar out of a short
    /// window. So in a pane too short for it plus a few lines of details,
    /// the top scrolls with the details, and only the footer stays put.
    /// Chosen from the measured heights rather than with `ViewThatFits`,
    /// which would measure both layouts again on every tick of the job's
    /// CPU and memory (as `ConnectionDetail` found).
    var body: some View {
        let restriction = LaunchControl.restriction(for: item)
        let pinsTop = height.map { $0 >= topHeight + 24 + Self.detailsMinimum + footerHeight + 2 } ?? true
        VStack(spacing: 0) {
            if pinsTop {
                top(restriction: restriction)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView { details.padding(12) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        top(restriction: restriction)
                        details
                    }
                    .padding(12)
                }
            }
            Divider()
            footer(restriction: restriction)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .task(id: ServiceRead(label: item.label, scope: item.scope, refreshID: refreshID,
                              pid: item.pid, lastExit: item.job?.lastExit)) {
            let (label, scope) = (item.label, item.scope)
            service = await Task.detached(priority: .userInitiated) { Launchctl.service(label, scope: scope) }.value
        }
    }

    /// What launchd's view is read again for: another item, a rescan, or a
    /// new process or exit seen by the page's lighter reads in between.
    private struct ServiceRead: Equatable {
        var label: String
        var scope: LaunchItemScope
        var refreshID: Date?
        var pid: Int32?
        var lastExit: LaunchExitStatus?
    }

    /// Room the details keep under the pinned top before it scrolls too.
    private static let detailsMinimum: CGFloat = 96

    // MARK: Sections

    private func top(restriction: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            state(restriction: restriction)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
    }

    /// The name shares its line with Show in List, so the label below keeps
    /// the pane's width.
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forBundle: item.appBundlePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Show in List", action: showInList)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Scroll the table to this item. A filter or search that hides it is cleared.")
                }
                Text(item.label)
                    .font(.callout.monospaced()).foregroundStyle(.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.label)
            }
        }
    }

    /// launchd's view in plain words ("Loaded · Not running"), and right
    /// below it the action that fits: Start Now while nothing runs, Restart
    /// and Stop while it does.
    private func state(restriction: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if health.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(LaunchJobHealth.tint)
                } else {
                    Circle().fill(item.state.color).frame(width: 8, height: 8)
                }
                Text(item.statusSummary).font(.callout.weight(.medium)).lineLimit(1)
            }
            .help(health.headline.map { "\(stateHelp) \($0)." } ?? stateHelp)
            if restriction == nil, item.job != nil {
                controls
            }
        }
    }

    /// launchd's figures for the job, then what the property list says. The
    /// arguments fold away and paths are a name over a folder, so nothing
    /// here needs a scroll view of its own.
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let headline = health.headline {
                trouble(headline)
            }
            facts
            if let note { Text(note).font(.explanation).foregroundStyle(.secondaryText) }
            launches
            program
            labelled("Property list", item.plistPath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The lasting change, Disable or Enable, with what it does, and the file itself.
    private func footer(restriction: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if restriction == nil {
                HStack(alignment: .firstTextBaseline) {
                    Button(item.isDisabled ? "Enable" : "Disable…", action: toggle)
                    Text(item.isDisabled ? "Loads it now and at every login." : "Stops it now and at every login, for your account.")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                }
            } else if item.publisher == .thirdParty, let restriction {
                Text(restriction).font(.explanation).foregroundStyle(.secondaryText)
            }
            // Wrapping onto a second line in a narrow pane.
            FlowRow(spacing: 8, lineSpacing: 8, spreads: false) {
                Button("Reveal in Finder") { StartupActions.reveal(item) }
                Button("Copy Path") { StartupActions.copyPath(item) }
                    .help("Copy the property list's whole path")
                Button("Show plist") { StartupActions.openPlist(item) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What launchd has done with the job, then what the property list says
    /// about it, which doesn't change as it runs.
    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if let disabledBy {
                FactRow(label: "Disabled by", value: disabledBy)
            }
            if let pid = item.pid {
                // The state above already shows the PID.
                GridRow {
                    Text("Using now").foregroundStyle(.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        JobUsageNow(model: model, pid: pid)
                        Button("Show in Processes") { showProcess(pid) }
                            .buttonStyle(.link)
                            .help("Select PID \(String(pid)) on the Processes page")
                    }
                }
                .font(.callout)
            }
            if let service { serviceRows(service) }
            if let record {
                GridRow {
                    Text("Restarts").foregroundStyle(.secondaryText).help(Self.restartsHelp)
                    Text(record.restartSummary(time: Self.clock)).help(Self.restartsHelp)
                }
                .font(.callout)
            }
            FactRow(label: "Last exit", value: lastExit)
            // A gap rather than a rule, which would read as another region.
            Color.clear.frame(height: 2).gridCellUnsizedAxes(.horizontal)
            FactRow(label: "Kind", value: item.scope.title)
            FactRow(label: "Publisher", value: item.publisher.title)
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
            DetailDisclosure(arguments.count == 1 ? "Argument" : "Arguments (\(arguments.count))",
                             preview: arguments.joined(separator: " "), isExpanded: $showsArguments) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                        CopyableText(value: argument).font(.callout)
                    }
                }
            }
        }
    }

    private var launches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launches").font(.callout).foregroundStyle(.secondaryText)
            if item.isUnreadable {
                Text("Unknown: the property list can't be read").font(.callout)
            } else {
                ForEach(item.triggers.details(for: item.scope), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondaryText)
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func serviceRows(_ service: LaunchServiceInfo) -> some View {
        if let runs = service.runs {
            GridRow {
                Text("Started").foregroundStyle(.secondaryText).help(runsHelp)
                Text(LaunchServiceInfo.describe(runs: runs, scope: item.scope)).help(runsHelp)
            }
            .font(.callout)
        }
        if item.pid != nil, let reason = service.startReason {
            GridRow {
                Text("Started by").foregroundStyle(.secondaryText)
                Text(LaunchServiceInfo.describe(startReason: reason))
                    .help("launchd's reason: \(reason)")
            }
            .font(.callout)
        }
        if let priority = service.priority {
            GridRow {
                Text("Priority").foregroundStyle(.secondaryText)
                Text(priority.title).help(priority.explanation)
            }
            .font(.callout)
        }
    }

    /// Start, restart and stop, for a loaded job this app may control, each
    /// with what it does beside it.
    private var controls: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            if item.pid != nil {
                GridRow {
                    Button("Restart") { control(.restart) }
                        .help("Stop the job and start it again")
                    consequence("Quits it and starts it again.")
                }
                GridRow {
                    Button("Stop") { control(.stop) }
                        .help(stopHelp)
                    consequence(afterStop)
                }
            } else {
                GridRow {
                    Button("Start Now") { control(.start) }
                        .help("Run the job now, whatever usually launches it")
                    consequence("Runs it once, now.")
                }
            }
        }
    }

    private func consequence(_ text: String) -> some View {
        Text(text)
            .font(.explanation)
            .foregroundStyle(.secondaryText)
            .gridColumnAlignment(.leading)
    }

    /// What's wrong, in a sentence or two, first in the details.
    private func trouble(_ headline: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.callout.weight(.semibold))
                if let explanation = health.explanation(for: item, record: record, time: Self.clock) {
                    Text(explanation).font(.explanation)
                }
            }
            .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LaunchJobHealth.tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LaunchJobHealth.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Text

    /// A clock time, "09:12", for the restarts.
    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static let restartsHelp = "New processes seen for this job since OpenTaskManager first read launchd's list. "
        + "It looks when the Startup page opens, on Refresh, and every \(Int(LaunchJobStore.readInterval.components.seconds)) "
        + "seconds while the page is on screen, so a job that restarts faster counts once between looks."

    private var stateHelp: String {
        switch item.state {
        case let .running(pid): "launchd started it, and its process (PID \(pid)) is running now."
        case .loaded: "launchd has loaded it and starts it whenever something launches it (see Launches). Nothing is running now."
        case .disabled: "Disabled: launchd won't start it until it's enabled again."
        case .notLoaded: "launchd hasn't loaded this property list, so nothing starts it."
        }
    }

    private var runsHelp: String {
        let since = item.scope == .daemon ? "the Mac started up" : "you logged in"
        return "How many times launchd has started the job since \(since). Between runs a loaded job waits "
            + "for whatever launches it, so it isn't always running."
    }

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

    /// A path shows its name over its folder, which wraps, with the whole of
    /// it in a tooltip and a copy button.
    private func labelled(_ label: String, _ value: String, isCode: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondaryText)
            CopyableText(value: value, monospaced: isCode, splitsPath: isCode).font(.callout)
        }
    }
}

/// The job's CPU and memory in the latest sample, "3.2% CPU · 45 MB", found
/// by the PID launchd gave. It reads the model itself, so a tick redraws
/// this line and not the pane.
private struct JobUsageNow: View {
    let model: AppModel
    var pid: Int32

    var body: some View {
        if let point = model.latestProcessPoint(pid: pid) {
            Text("\(model.cpuScale.format(point.cpuPercent)) CPU · \(Format.bytes(point.memory))")
                .monospacedDigit()
                .help("PID \(String(pid)) in the latest sample, as the Processes page shows it")
        } else {
            Text("Not in the latest sample")
                .foregroundStyle(.secondaryText)
                .help(JobUsageText.notSampled(pid))
        }
    }
}
