import OTMKit
import SwiftUI

@main
struct OpenTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("streamGraphs") private var streamGraphs = true

    init() {
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

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
                .environment(\.sampleInterval, model.updateSpeed.rawValue)
                .environment(\.streamsGraphs, streamGraphs)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case processes = "Processes"
    case performance = "Performance"
    case startup = "Startup"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle"
        case .performance: "waveform.path.ecg"
        case .startup: "sunrise"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("page") private var page: Page = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { page }, set: { if let new = $0 { page = new } })) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            switch page {
            case .overview: OverviewView()
            case .processes: ProcessesView()
            case .performance: PerformanceView()
            case .startup: StartupView()
            }
        }
        .navigationTitle(page.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .help(model.isPaused ? "Resume live updates (⇧⌘P)" : "Freeze the display (⇧⌘P)")
            }
            ToolbarItem(placement: .navigation) {
                LiveBadge(isPaused: model.isPaused, interval: model.updateSpeed.rawValue)
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

/// Says whether the numbers are moving, and how often they update.
private struct LiveBadge: View {
    var isPaused: Bool
    var interval: Double

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPaused ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(isPaused ? "Paused" : "Live · \(Format.timeSpan(interval))")
                .font(.caption.weight(.medium))
                .foregroundStyle(isPaused ? Color.orange : Color.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((isPaused ? Color.orange : Color.green).opacity(0.12), in: Capsule())
        .help(isPaused ? "Updates are frozen. Press ⇧⌘P to resume." : "Updating every \(Format.timeSpan(interval)). Change it in Settings.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(history: model.cpuHistory.values, usage: model.snapshot?.cpu.usage ?? 0))
            .accessibilityLabel("CPU \(Format.percent(model.snapshot?.cpu.usage ?? 0))")
            .onAppear {
                WindowOpener.openMainWindow = { openWindow(id: "main") }
            }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                meter("CPU", Format.percent(snapshot.cpu.usage), model.cpuHistory.values, Theme.cpu, 1)
                meter("Memory", "\(Format.bytes(snapshot.memory.used)) · \(snapshot.memory.pressure.rawValue)",
                      model.memoryHistory.values, Theme.memory, 1)
                if let gpu = snapshot.gpus.first {
                    meter("GPU", Format.percent(gpu.deviceUtilization), model.gpuHistory[gpu.id]?.values ?? [], Theme.gpu, 1)
                }
                if let watts = snapshot.power.systemWatts {
                    meter("Power", Format.watts(watts), model.powerHistory.values, Theme.power, nil)
                }

                Divider()
                Text("Top processes").font(.caption).foregroundStyle(.secondary)
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
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
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
                Text(title).font(.caption).foregroundStyle(.secondary)
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
