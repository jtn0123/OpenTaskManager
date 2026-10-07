import OTMKit
import SwiftUI

@main
struct OpenTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @AppStorage("streamGraphs") private var streamGraphs = true

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        StatusItemController.shared.model = model
        // `--args -openPage Processes` picks the starting page. It's copied into the
        // saved value once, because passing `-page` itself would pin that setting
        // for the whole run and the sidebar would stop switching pages.
        if let start = UserDefaults.standard.string(forKey: "openPage"), Page(rawValue: start) != nil {
            UserDefaults.standard.set(start, forKey: "page")
        }
    }

    var body: some Scene {
        Window("OpenTaskManager", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.sampleInterval, model.updateSpeed.rawValue)
                .environment(\.streamsGraphs, streamGraphs)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Recording…") { HistoryRecordingStore.shared.chooseRecording() }
                    .keyboardShortcut("o")
            }
            // View > Hide Sidebar and Show Sidebar (⌃⌘S). A window under
            // 900 points hides it by itself (`SidebarVisibility`).
            SidebarCommands()
            PageCommands()
            CommandGroup(after: .toolbar) {
                Button(model.isPaused ? "Resume Updates" : "Pause Updates") { model.isPaused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Refresh Now") { model.refreshNow() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case processes = "Processes"
    case performance = "Performance"
    case history = "History"
    case connections = "Connections"
    case startup = "Startup"
    case apps = "Apps"
    case users = "Users"
    case system = "System"
    case drivers = "Drivers"
    case storage = "Storage"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle"
        case .performance: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .startup: "sunrise"
        case .apps: "square.grid.3x3"
        case .users: "person.2"
        case .system: "info.circle"
        case .drivers: "puzzlepiece.extension"
        case .storage: "internaldrive"
        }
    }

    /// ⌘1 to ⌘9 for the first nine pages, in the View menu and the page menu.
    var shortcut: KeyboardShortcut? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
    }
}

/// The pages in the View menu, the current one ticked, with ⌘1 to ⌘9 for the
/// first nine: a way between pages that doesn't need the sidebar, which a
/// window under 900 points hides.
private struct PageCommands: Commands {
    @AppStorage("page") private var page: Page = .overview

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Section {
                ForEach(Page.allCases) { item in
                    Toggle(item.rawValue, isOn: Binding(get: { page == item }, set: { if $0 { page = item } }))
                        .keyboardShortcut(item.shortcut)
                }
            }
        }
    }
}

/// The toolbar's page menu, there only while the sidebar is hidden: the
/// page's icon with a chevron, just before the title that names the page,
/// and every page in its menu, the current one ticked, with its ⌘ shortcut.
/// A narrow window hides the sidebar, and with it every page that could be
/// seen; the View menu's list has to be known about. A real toolbar item,
/// since a menu on the title itself did nothing on macOS 26. The title keeps
/// the name: taking it out of the toolbar for a menu that carried the name
/// sent the sidebar's own toggle to the overflow menu, for good, once the
/// sidebar was shown in a narrow window (macOS 26).
private struct PageSwitcher: View {
    @Binding var page: Page

    var body: some View {
        Menu {
            ForEach(Page.allCases) { item in
                Toggle(isOn: Binding(get: { page == item }, set: { if $0 { page = item } })) {
                    Label(item.rawValue, systemImage: item.symbol)
                }
                .keyboardShortcut(item.shortcut)
            }
        } label: {
            Label(page.rawValue, systemImage: page.symbol)
                .labelStyle(.iconOnly)
        }
        .fixedSize()
        .help("Go to another page. ⌘1 to ⌘9 switch from anywhere, and the sidebar, hidden while the window "
            + "is narrow, lists them too.")
        .accessibilityLabel("Page")
        .accessibilityValue(page.rawValue)
        .accessibilityHint("Shows the list of pages")
    }
}

struct ContentView: View {
    /// Where the user's own hiding of the sidebar, in a wide window, is kept.
    private static let sidebarHiddenKey = "sidebarHidden"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("page") private var page: Page = .overview
    /// In a window under 900 points the sidebar steps aside, so the page gets
    /// the fifth of the width it took, and comes back when the window
    /// widens; the user's own show or hide wins (`SidebarVisibility` in OTMKit).
    /// It starts from the width the window opens at (its saved frame), so a
    /// window that opens narrow never shows it. Hidden only once the window
    /// was measured, it flashed by, and its list, focused by then, passed
    /// the focus on to the toolbar's sidebar button.
    @State private var sidebar = SidebarVisibility(
        hiddenByUser: UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey),
        windowWidth: SidebarVisibility.openingWidth(savedFrame: UserDefaults.standard.string(forKey: "NSWindow Frame main"))
    )

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebar.isShown ? .all : .detailOnly },
            // The toolbar's sidebar button and View > Hide Sidebar.
            set: { sidebar.userSets(shown: $0 != .detailOnly) }
        )) {
            List(Page.allCases, selection: Binding(get: { page }, set: { if let new = $0 { page = new } })) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            // As narrow as the longest name ("Connections") allows, and no
            // narrower: an icon-only sidebar had no room for the system's
            // toggle, which then went to the toolbar's overflow menu. A
            // narrow window hides the whole column instead.
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 240)
        } detail: {
            Group {
                switch page {
                case .overview: OverviewView()
                case .processes: ProcessesView()
                case .performance: PerformanceView()
                case .history: HistoryView()
                case .connections: ConnectionsView()
                case .startup: StartupView()
                case .apps: AppsView()
                case .users: UsersView()
                case .system: SystemInfoView()
                case .drivers: DriversView()
                case .storage: StorageView()
                }
            }
            // The page takes the window's height, whatever it would ask
            // for. Left to itself, a page's height ruled the split view's:
            // Storage's scanning stage asked for 912 points in a 760-point
            // window, so the split view, centred below the toolbar, began
            // 50 points above the window (Connections, 4). AppKit then gave
            // the detail column a toolbar backdrop of its own, laid out for
            // that position, which stayed 50 points down the page once the
            // scan ended and the split view moved back: a white band over
            // Storage's top cards. A page too tall for the window now
            // overflows inside the column instead (the window's minimum
            // height never followed the pages either).
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        // Only crossing the breakpoint matters, not every step of a resize.
        .onGeometryChange(for: Bool.self) { SidebarVisibility.isNarrow(width: $0.size.width) } action: { narrow in
            sidebar.window(isNarrow: narrow)
        }
        // With the sidebar hidden, the focus goes to the page's main table
        // or nowhere, not to the toolbar's sidebar button.
        .background(PageFocus(page: page, sidebarShown: sidebar.isShown))
        .onChange(of: sidebar.hiddenByUser) { UserDefaults.standard.set(sidebar.hiddenByUser, forKey: Self.sidebarHiddenKey) }
        // With the sidebar hidden, the title still names the page, and the
        // page menu just before it (`PageSwitcher`) and the View menu (⌘1
        // to ⌘9, `PageCommands`) change it.
        .navigationTitle(page.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                // Just the icon while the page menu shares a narrow window's
                // toolbar: the word pushed Startup's, Apps' and Drivers'
                // Refresh, and System's Copy Summary, into the overflow menu.
                .labelStyle(showsTitle: sidebar.isShown || sidebar.isNarrow != true)
                .help(model.isPaused ? "Resume live updates (⇧⌘P)" : "Freeze the display (⇧⌘P)")
            }
            ToolbarItem(placement: .navigation) {
                LiveBadge()
            }
            if !sidebar.isShown {
                ToolbarItem(placement: .navigation) {
                    PageSwitcher(page: $page)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .onAppear {
            WindowOpener.openMainWindow = { openWindow(id: "main") }
        }
    }
}

private extension View {
    /// The label's title and icon, or the icon alone; the title still names
    /// it to VoiceOver either way.
    @ViewBuilder func labelStyle(showsTitle: Bool) -> some View {
        if showsTitle {
            labelStyle(.titleAndIcon)
        } else {
            labelStyle(.iconOnly)
        }
    }
}

/// Says whether the metrics are moving and how often they update: "Live
/// metrics · 1 s". It speaks for the sampled figures alone; the inventory
/// pages (Startup, Apps, Drivers) say when their lists were read beside
/// their own Refresh. Clicking it opens a popover to change the update
/// speed. While the History page shows a recording file, the badge answers
/// only for this Mac's own figures: "Collecting · 1 s", or "Collecting
/// paused" in grey, so orange is the replay's alone, and the replay's badge
/// follows it in that tint. The recording's name stays in the page's
/// banner, which leaves the page's toolbar items room at 820 points.
private struct LiveBadge: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosing = false

    var body: some View {
        let isPaused = model.isPaused
        let replay = HistoryRecordingStore.shared.replay
        let replaying = replay != nil
        let tint = !isPaused ? Color.green : replaying ? Color.secondary : Color.orange
        HStack(spacing: 6) {
            Button {
                isChoosing.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                    Text(replaying ? (isPaused ? "Collecting paused" : "Collecting") : isPaused ? "Metrics paused" : "Live metrics")
                        .fontWeight(.semibold)
                        .foregroundStyle(isPaused && !replaying ? Color.orange : Color.primary)
                    if !isPaused {
                        Text("· " + Format.timeSpan(model.updateSpeed.rawValue))
                            .foregroundStyle(.secondaryText)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondaryText)
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(tint.opacity(0.13), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(help(replaying: replaying))
            .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
                UpdateSpeedPicker()
                    .environment(model)
            }
            if let replay {
                HistoryReplayBadge(status: replay)
            }
        }
    }

    private func help(replaying: Bool) -> String {
        let every = Format.timeSpan(model.updateSpeed.rawValue)
        guard replaying else {
            let lists = "Startup, Apps and Drivers are lists read when their page opens and on Refresh, which says when."
            return model.isPaused
                ? "Metrics are frozen. Press ⇧⌘P to resume. \(lists)"
                : "Metrics (CPU, memory, GPU, disk, network, power) update \(Self.every(model.updateSpeed.rawValue)). "
                    + "\(lists) Click to change the speed."
        }
        return model.isPaused
            ? "Collecting this Mac's own figures is paused, so its history gains nothing; the recording replays on its own. "
                + "Press ⇧⌘P to resume."
            : "This Mac's own figures are still collected every \(every), and its history kept, while the recording replays. "
                + "Click to change the speed. Pause stops collecting, not the replay."
    }

    /// "every second", "every 2 s".
    private static func every(_ seconds: Double) -> String {
        seconds == 1 ? "every second" : "every \(Format.timeSpan(seconds))"
    }
}

/// The badge's popover: the update speed and the pause switch in one place.
private struct UpdateSpeedPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Update metrics every").font(.headline)
            Picker("Update metrics every", selection: $model.updateSpeed) {
                ForEach(UpdateSpeed.allCases) { Text(Format.timeSpan($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Graphs hold the last \(AppModel.graphSpan) updates, so slower speeds show a longer stretch and use less CPU.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Pause updates", isOn: $model.isPaused)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 270)
    }
}

// MARK: - Menu bar

/// The summary under the menu bar item (`StatusItemController`).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                meter("CPU", Format.percent(snapshot.cpu.usage), model.cpuHistory.values, Theme.cpu, 1)
                meter("Memory", "\(Format.bytes(snapshot.memory.used)) · \(snapshot.memory.pressure.rawValue)",
                      model.memoryHistory.values, Theme.memory, 1)
                if let gpu = snapshot.gpus.first {
                    meter("GPU", gpu.deviceUtilization.map { Format.percent($0) } ?? Unavailable.gpuUtilization,
                          model.gpuHistory[gpu.id]?.values ?? [], Theme.gpu, 1)
                }
                if let watts = snapshot.power.systemWatts {
                    meter("Power", Format.watts(watts), model.powerHistory.values, Theme.power, nil)
                }

                Divider()
                Text("Top processes").font(.subheadline).foregroundStyle(.secondary)
                ForEach(snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5), id: \.pid) { process in
                    HStack(spacing: 6) {
                        Image(nsImage: IconCache.icon(for: process, app: model.regularApps[process.pid]))
                            .resizable().frame(width: 14, height: 14)
                        Text(model.displayName(for: process)).lineLimit(1)
                        Spacer()
                        Text(model.cpuScale.format(process.cpuPercent)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            } else {
                ProgressView()
            }

            Divider()
            HStack {
                Button("Open OpenTaskManager") {
                    StatusItemController.shared.close()
                    WindowOpener.showMainWindow()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func meter(_ title: String, _ value: String, _ values: [Double], _ color: Color, _ max: Double?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
            }
            Spacer()
            Sparkline(values: values, color: color, maxValue: max, capacity: 60)
                .frame(width: 120, height: 30)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("globalHotKeyEnabled") private var globalHotKeyEnabled = true
    @AppStorage("heatmap") private var heatmap = true
    @AppStorage("streamGraphs") private var streamGraphs = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Updates") {
                Picker("Update speed", selection: $model.updateSpeed) {
                    ForEach(UpdateSpeed.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Scroll graphs smoothly between updates", isOn: $streamGraphs)
            }
            Section("Processes") {
                Toggle("Include system and other users' processes", isOn: $model.includeSystemProcesses)
                Toggle("Meter bars behind busy values", isOn: $heatmap)
                Picker("Process CPU", selection: $model.cpuRelativeToSystem) {
                    Text("Share of the whole CPU (max 100%)").tag(true)
                    Text("100% per core, like Activity Monitor").tag(false)
                }
            }
            Section("Access") {
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                Toggle("Open with ⌃⇧⎋ from anywhere", isOn: $globalHotKeyEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
