import AppKit
import OTMKit
import SwiftUI

/// Who is using the Mac: each person's processes added up, with a minute of
/// CPU and memory history, their logins and their busiest processes. Root
/// and the service accounts sit together underneath, collapsed until opened.
struct UsersView: View {
    @Environment(AppModel.self) private var model
    @State private var console: ConsoleUser?
    @State private var sessions: [LoginSession] = []
    /// Users whose top processes are showing.
    @State private var expanded: Set<UInt32> = []
    @State private var showsSystemAccounts = false
    /// `--args -openUser root` expands that user once the first sample arrives.
    @State private var pendingUser = LaunchArgument.string("openUser")
    /// Set once the page has opened a lone person's top processes, so
    /// closing them sticks.
    @State private var openedOnlyPerson = false

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await followSessions() }
        .onChange(of: model.users.count, initial: true) {
            openRequestedUser()
            openOnlyPerson()
        }
    }

    private func content(_ snapshot: SystemSnapshot) -> some View {
        // `model.users` is already in order (people by name, root, then the
        // services), so only the signed-in user needs moving to the front.
        let people = model.users.filter { !$0.isSystemAccount && $0.uid == console?.uid }
            + model.users.filter { !$0.isSystemAccount && $0.uid != console?.uid }
        let system = model.users.filter(\.isSystemAccount)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: "Users", subtitle: summary(people: people, system: system, processes: snapshot.processes.count))
                if !people.isEmpty {
                    FillGrid(minimum: 520) {
                        ForEach(Array(people.enumerated()), id: \.element.uid) { index, user in
                            PersonCard(
                                user: user,
                                account: model.account(for: user.uid),
                                isSignedIn: user.uid == console?.uid,
                                sessions: sessions.filter { $0.user == user.name },
                                tint: Theme.series(index),
                                isExpanded: expansion(of: user.uid)
                            )
                        }
                    }
                }
                if !system.isEmpty {
                    SystemAccountsCard(users: system, isOpen: $showsSystemAccounts, expanded: $expanded)
                }
                footnote
            }
            .padding(20)
        }
        .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory is each process's memory added up. Memory that processes share counts once for each of them, "
                + "so a user's total can be more than they hold on their own.")
            Text("macOS shares only CPU and memory for processes owned by root and other users; “—” marks what it doesn't report.")
            if !model.includeSystemProcesses {
                Text("Only your own processes are included. Turn on “Include system and other users' processes” in Settings to see everyone.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func summary(people: [UserUsage], system: [UserUsage], processes: Int) -> String {
        var parts = [UsersText.count(people.count, "person", "people")]
        if !system.isEmpty { parts.append(UsersText.count(system.count, "system account", "system accounts")) }
        parts.append(UsersText.count(processes, "process", "processes"))
        return parts.joined(separator: " · ")
    }

    private func expansion(of uid: UInt32) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(uid) },
            set: { if $0 { expanded.insert(uid) } else { expanded.remove(uid) } }
        )
    }

    private func openRequestedUser() {
        guard let name = pendingUser, let user = model.users.first(where: { $0.name == name || String($0.uid) == name }) else { return }
        expanded.insert(user.uid)
        if user.isSystemAccount { showsSystemAccounts = true }
        pendingUser = nil
    }

    /// With one person on the Mac, the page has room for their busiest
    /// processes, so they start open.
    private func openOnlyPerson() {
        guard !openedOnlyPerson, pendingUser == nil else { return }
        let people = model.users.filter { !$0.isSystemAccount }
        guard !people.isEmpty else { return }
        openedOnlyPerson = true
        if people.count == 1 { expanded.insert(people[0].uid) }
    }

    /// Who's at the screen and who's logged in change rarely, so check every
    /// ten seconds rather than every sample.
    private func followSessions() async {
        while !Task.isCancelled {
            let (user, list) = await Task.detached(priority: .utility) {
                (UserAccounts.consoleUser(), UserAccounts.sessions())
            }.value
            if user != console { console = user }
            if list != sessions { sessions = list }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

enum UsersText {
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    /// "since 9:41 AM" today, "since Oct 3, 9:41 AM" before that.
    static func since(_ date: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day().hour().minute()
        return "since " + date.formatted(style)
    }

    static let restrictedHelp = "macOS doesn't report this for processes owned by root or other users."
}

// MARK: - People

/// A person's card: who they are, what their processes use, and where they're logged in.
private struct PersonCard: View {
    @Environment(AppModel.self) private var model
    var user: UserUsage
    var account: UserAccount?
    var isSignedIn: Bool
    var sessions: [LoginSession]
    var tint: Color
    @Binding var isExpanded: Bool

    var body: some View {
        let totals = user.totals
        let scale = model.cpuScale
        let history = model.userHistory[user.uid]
        Card(tint: tint, glow: min(totals.cpuPercent / Double(100 * max(scale.logicalCores, 1)), 1)) {
            header
            FillGrid(minimum: 230, spacing: 14) {
                UserGraph(
                    label: "CPU", caption: scale.relativeToSystem ? "Share of the whole CPU" : "100% per core",
                    number: scale.value(totals.cpuPercent), format: { Format.fixed($0, 1) + "%" },
                    values: (history?.cpu.values ?? []).map(scale.value), color: Theme.cpu,
                    minimumCeiling: scale.relativeToSystem ? 5 : 50,
                    maximumCeiling: scale.relativeToSystem ? 100 : Double(100 * max(scale.logicalCores, 1)),
                    axis: { Format.fixed($0, 0) + "%" }
                )
                UserGraph(
                    label: "Memory", caption: "Sum of process memory",
                    number: Double(totals.memory), format: MemoryDetail.bytesAxis,
                    values: history?.memory.values ?? [], color: Theme.memory,
                    minimumCeiling: 256 * 1_048_576, axis: MemoryDetail.bytesAxis, axisUnits: .binaryBytes
                )
                .help(totals.includesResidentMemory
                    ? "Each process's memory added up. Processes macOS hides details of count their resident size."
                    : "Each process's memory footprint added up.")
            }
            UserStats(totals: totals)
            if !sessions.isEmpty { SessionList(sessions: sessions) }
            Expander(title: "Top processes", isExpanded: $isExpanded)
            if isExpanded, let processes = model.snapshot?.processes {
                TopProcessList(processes: UserUsageBuilder.topProcesses(of: user.uid, in: processes, count: 8))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            UserAvatar(name: account?.fullName ?? user.name, color: tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account?.fullName ?? user.name).font(.title3.weight(.semibold)).lineLimit(1)
                    if isSignedIn {
                        Badge(text: "Signed in", color: Theme.data(.systemGreen))
                            .help("This user is signed in at the screen.")
                    } else if !sessions.isEmpty {
                        Badge(text: "Logged in", color: Theme.data(.systemBlue))
                            .help("This user has a terminal or remote login but isn't at the screen.")
                    }
                }
                Text(([user.name, "uid \(user.uid)"] + (account?.homeDirectory.map { [$0] } ?? [])).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A live figure over a minute-long graph.
private struct UserGraph: View {
    var label: String
    var caption: String
    var number: Double
    var format: (Double) -> String
    var values: [Double]
    var color: Color
    var minimumCeiling: Double
    var maximumCeiling: Double = .infinity
    var axis: (Double) -> String
    var axisUnits: GraphMath.AxisUnits = .plain

    private static let span = AppModel.userHistoryCapacity - 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom) {
                Stat(label: label, number: number, color: color, format: format)
                Spacer(minLength: 8)
                Text(caption).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
            }
            GraphView(series: [GraphSeries(values: values, color: color)], capacity: Self.span, glows: true,
                      minimumCeiling: minimumCeiling, maximumCeiling: maximumCeiling, axis: axis, axisUnits: axisUnits,
                      cornerRadius: 8)
                .chartFrame(height: 76, tint: color)
            TimeAxis(samples: Self.span)
        }
    }
}

/// Counts plus the readings macOS only gives for the user's own processes.
private struct UserStats: View {
    var totals: UsageTotals

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Stat(label: "Processes", value: totals.processCount.formatted())
            Stat(label: "Threads", value: totals.threads.formatted())
            Stat(label: "Power", value: totals.powerWatts.map(Format.watts) ?? "—")
                .help(totals.powerWatts == nil ? UsersText.restrictedHelp : "Energy use of these processes right now.")
            Stat(label: "GPU", value: totals.gpuFraction.map { Format.percent($0) } ?? "—")
                .help(totals.gpuFraction == nil ? "None of these processes have used the GPU." : "GPU time of these processes.")
        }
    }
}

/// The user's logins: the screen, Terminal windows and remote shells.
private struct SessionList: View {
    var sessions: [LoginSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions").font(.metadata).foregroundStyle(.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(sessions) { session in
                    HStack(spacing: 6) {
                        Image(systemName: session.isConsole ? "display" : session.host == nil ? "terminal" : "network")
                            .foregroundStyle(.secondaryText)
                        Text(session.place).lineLimit(1).truncationMode(.middle)
                        Text(UsersText.since(session.loginTime)).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                    .font(.callout)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
                    .help("Logged in \(session.loginTime.formatted(date: .complete, time: .standard)) · process \(session.pid)")
                }
            }
        }
    }
}

// MARK: - System accounts

/// Root and the accounts macOS runs its services under, summed in the header
/// and listed one row each when opened.
private struct SystemAccountsCard: View {
    @Environment(AppModel.self) private var model
    var users: [UserUsage]
    @Binding var isOpen: Bool
    @Binding var expanded: Set<UInt32>

    var body: some View {
        let totals = UserUsageBuilder.total(users)
        let scale = model.cpuScale
        let cpuHistory = AppModel.tailSum(users.compactMap { model.userHistory[$0.uid]?.cpu.values }).map(scale.value)
        Card(tint: UsersText.systemTint, glow: min(totals.cpuPercent / Double(100 * max(scale.logicalCores, 1)), 1)) {
            Button { isOpen.toggle() } label: {
                HeadingRow(spacing: 12, indent: 82) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondaryText)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 14)
                        Image(systemName: "gearshape.2")
                            .font(.title2)
                            .foregroundStyle(UsersText.systemTint)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(UsersText.systemTint.fillShade.opacity(0.18)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("System accounts").font(.title3.weight(.semibold)).lineLimit(1)
                            Text(subtitle(totals)).font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
                        }
                    }
                    HStack(spacing: 12) {
                        Stat(label: "CPU", number: scale.value(totals.cpuPercent), color: Theme.cpu, format: { Format.fixed($0, 1) + "%" })
                        Stat(label: "Memory", number: Double(totals.memory), color: Theme.memory, format: MemoryDetail.bytesAxis)
                        Sparkline(values: cpuHistory, color: Theme.cpu, capacity: AppModel.userHistoryCapacity - 2)
                            .frame(width: 140, height: 34)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide system accounts" : "Show each system account")

            if isOpen {
                Divider()
                SystemAccountGrid(users: users, expanded: $expanded)
            }
        }
    }

    private func subtitle(_ totals: UsageTotals) -> String {
        let services = users.filter { $0.uid != 0 }.count
        let who = users.contains { $0.uid == 0 }
            ? "root and " + UsersText.count(services, "service account", "service accounts")
            : UsersText.count(services, "service account", "service accounts")
        return who + " · " + UsersText.count(totals.processCount, "process", "processes")
    }
}

/// A heading with its figures at the trailing end, or under it, indented,
/// when the two don't fit side by side, so the heading never wraps.
private struct HeadingRow: Layout {
    var spacing: CGFloat
    /// How far in the figures start on their own row.
    var indent: CGFloat
    private let rowGap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let (heading, figures) = sizes(subviews) else { return .zero }
        let sideBySide = heading.width + spacing + figures.width
        let width = proposal.width ?? sideBySide
        if sideBySide <= width { return CGSize(width: width, height: max(heading.height, figures.height)) }
        return CGSize(width: width, height: heading.height + rowGap + figures.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let (heading, figures) = sizes(subviews) else { return }
        if heading.width + spacing + figures.width <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(heading))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(figures))
        } else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: heading.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + indent, y: bounds.minY + heading.height + rowGap),
                               proposal: ProposedViewSize(figures))
        }
    }

    private func sizes(_ subviews: Subviews) -> (CGSize, CGSize)? {
        guard subviews.count == 2 else { return nil }
        return (subviews[0].sizeThatFits(.unspecified), subviews[1].sizeThatFits(.unspecified))
    }
}

/// One row per system account, each opening onto its busiest processes.
private struct SystemAccountGrid: View {
    @Environment(AppModel.self) private var model
    var users: [UserUsage]
    @Binding var expanded: Set<UInt32>

    var body: some View {
        let scale = model.cpuScale
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Account")
                Text("Processes").gridColumnAlignment(.trailing)
                Text("CPU").gridColumnAlignment(.trailing)
                Text("Memory").gridColumnAlignment(.trailing)
                Text("Power").gridColumnAlignment(.trailing)
                Text("GPU").gridColumnAlignment(.trailing)
                Text("Last minute")
            }
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            ForEach(users) { user in
                let isExpanded = expanded.contains(user.uid)
                GridRow {
                    Button { toggle(user.uid) } label: { accountLabel(user, isExpanded: isExpanded) }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Hide \(user.name)'s processes" : "Show \(user.name)'s busiest processes")
                    Text(user.totals.processCount.formatted())
                    Text(scale.format(user.totals.cpuPercent))
                    Text(Format.bytes(user.totals.memory))
                    Text(user.totals.powerWatts.map(Format.watts) ?? "—")
                        .tooltip(user.totals.powerWatts == nil ? UsersText.restrictedHelp : nil)
                    Text(user.totals.gpuFraction.map { Format.percent($0) } ?? "—")
                    Sparkline(values: (model.userHistory[user.uid]?.cpu.values ?? []).map(scale.value), color: Theme.cpu,
                              capacity: AppModel.userHistoryCapacity - 2)
                        .frame(width: 110, height: 18)
                }
                .font(.callout)
                .monospacedDigit()
                if isExpanded, let processes = model.snapshot?.processes {
                    TopProcessList(processes: UserUsageBuilder.topProcesses(of: user.uid, in: processes, count: 6))
                        .padding(.leading, 40)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func accountLabel(_ user: UserUsage, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            UserAvatar(name: user.name, color: UsersText.systemTint, size: 22)
            Text(user.name).lineLimit(1)
            if let fullName = model.account(for: user.uid)?.fullName {
                Text(fullName).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func toggle(_ uid: UInt32) {
        if expanded.contains(uid) { expanded.remove(uid) } else { expanded.insert(uid) }
    }
}

extension UsersText {
    static let systemTint = Theme.data(0.56, 0.60, 0.68)
}

// MARK: - Parts

/// A user's busiest processes, most CPU first.
private struct TopProcessList: View {
    @Environment(AppModel.self) private var model
    var processes: [ProcessSample]

    var body: some View {
        if processes.isEmpty {
            Text("No processes right now.").font(.callout).foregroundStyle(.secondaryText)
        } else {
            let scale = model.cpuScale
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Process")
                    Text("PID").gridColumnAlignment(.trailing)
                    Text("CPU").gridColumnAlignment(.trailing)
                    Text("Memory").gridColumnAlignment(.trailing)
                    Text("Power").gridColumnAlignment(.trailing)
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                ForEach(processes, id: \.pid) { process in
                    GridRow {
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.icon(for: process, app: model.regularApps[process.pid]))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(model.displayName(for: process)).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(process.pid)).foregroundStyle(.secondaryText)
                        Text(scale.format(process.cpuPercent))
                        Text(Format.bytes(process.memory))
                        Text(process.powerWatts.map(Format.watts) ?? "—")
                            .tooltip(process.powerWatts == nil && process.isRestricted ? UsersText.restrictedHelp : nil)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
        }
    }
}

/// A disclosure row that doesn't animate, so opening it costs one layout.
private struct Expander: View {
    var title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Text(title)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A circle with the user's initials.
private struct UserAvatar: View {
    var name: String
    var color: Color
    var size: CGFloat

    var body: some View {
        Text(UserAccounts.initials(name))
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.55)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            .accessibilityHidden(true)
    }
}

private extension View {
    /// A help tag only when there's something to say.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

private struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.metadata.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.fillShade.opacity(0.18), in: Capsule())
    }
}
