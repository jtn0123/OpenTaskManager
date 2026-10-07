import OTMKit
import SwiftUI

/// How History words and draws spike captures (`SpikeCaptureStore`).
enum HistorySpikeStyle {
    static func symbol(_ kind: SpikeKind?) -> String {
        switch kind {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .thermal: "thermometer.high"
        case .disk: "internaldrive"
        case .network: "network"
        case nil: "bolt"
        }
    }

    static func color(_ kind: SpikeKind?) -> Color {
        switch kind {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .thermal: Theme.thermal
        case .disk: Theme.disk
        case .network: Theme.network
        case nil: HistorySessionStyle.tint
        }
    }

    /// What starts a capture, for the list and Settings.
    static let explanation = "When the whole CPU stays above 80% for 10 seconds, memory or thermal pressure rises, or disk or "
        + "network traffic runs well above its usual rate, OpenTaskManager keeps this Mac's figures second by second from "
        + "2 minutes before to 1 minute after, with the busiest processes. Each kind waits 10 minutes before it can capture "
        + "again. The newest 20 are kept, in Application Support."

    /// "yes 48%, yes 46%, WindowServer 2% of the CPU time": the busiest
    /// few, their figures shortened, the measure said once at the end.
    static func contributors(_ incident: SpikeIncident, count: Int = 3) -> String? {
        let shown = incident.contributors.prefix(count)
        guard let measure = shown.first?.measure else { return nil }
        let parts = shown.map { contributor in
            switch measure {
            case .cpu: "\(contributor.name) \(contributor.share.map { Format.percent($0) } ?? Format.percent(contributor.average / 100))"
            case .memory: "\(contributor.name) \(Format.bytes(contributor.peak))"
            case .disk: "\(contributor.name) \(Format.bytesPerSecond(contributor.average))"
            }
        }
        let tail = switch measure {
        case .cpu: shown.allSatisfy { $0.share != nil } ? " of the CPU time" : " of a core"
        case .memory: " at most"
        case .disk: " on average"
        }
        return parts.joined(separator: ", ") + tail
    }

    /// The contributors one a line, with PIDs, for a tooltip.
    static func contributorLines(_ incident: SpikeIncident) -> String {
        incident.contributors.map { "\($0.name) (PID \($0.identity.pid)): \($0.figureText)" }.joined(separator: "\n")
    }
}

/// The toolbar's Spikes button: the list of spike captures, with a dot
/// when one has come in since it was last opened and a filled bolt while
/// one is under way. Reads only the store's list, so a tick redraws nothing.
struct HistorySpikesButton: View {
    @State private var store = SpikeCaptureStore.shared
    @State private var showsList = false
    /// `-openSpikes YES` opens the list once, for screenshots.
    private static var openedAtLaunch = false

    var body: some View {
        Button {
            showsList.toggle()
        } label: {
            Label {
                Text("Spikes")
            } icon: {
                Image(systemName: store.capturing == nil ? "bolt" : "bolt.fill")
                    .overlay(alignment: .topTrailing) {
                        if store.unseen > 0 {
                            Circle()
                                .fill(HistorySessionStyle.tint)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .help(help)
        .accessibilityLabel(store.unseen > 0 ? "Spikes, \(store.unseen) new" : "Spikes")
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            HistorySpikesList(store: store, dismiss: { showsList = false })
        }
        .onChange(of: showsList) { if showsList { store.markSeen() } }
        .task {
            store.refresh()
            if !Self.openedAtLaunch, LaunchArgument.string("openSpikes") == "YES" {
                Self.openedAtLaunch = true
                try? await Task.sleep(for: .milliseconds(600))
                showsList = true
            }
        }
    }

    private var help: String {
        if let kind = store.capturing { return "Capturing a \(kind.label.lowercased()) spike. Spike captures: open the list" }
        let count = store.captures?.count ?? 0
        let saved = count == 0 ? "none saved" : count == 1 ? "1 saved" : "\(count) saved"
        let new = store.unseen > 0 ? ", \(store.unseen) new" : ""
        return "Spike captures (\(saved)\(new)): a second-by-second record of the minutes around each time the Mac got busy"
    }
}

/// The Spikes popover: the setting, what it does, and the captures, newest
/// first. A row opens its capture for replay, like an opened recording.
struct HistorySpikesList: View {
    @Bindable var store: SpikeCaptureStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spikes")
                        .font(.headline)
                    Spacer()
                    Toggle("Capture spikes automatically", isOn: $store.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Watch each update for spikes and keep a capture of each")
                }
                Text(store.isEnabled ? HistorySpikeStyle.explanation
                     : "Off: nothing is watched or written. " + HistorySpikeStyle.explanation)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let kind = store.capturing {
                    Label("Capturing a \(kind.label.lowercased()) spike: it's saved a minute after it began.",
                          systemImage: "record.circle")
                        .font(.explanation)
                        .foregroundStyle(HistorySpikeStyle.color(kind))
                }
            }
            .padding(14)
            Divider()
            list
            Divider()
            HStack {
                Text(footer)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                Spacer()
                Button("Show in Finder") { store.revealFolder() }
                    .help(store.library.directory.path)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 440)
    }

    @ViewBuilder private var list: some View {
        if let captures = store.captures, !captures.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(captures) { entry in
                        HistorySpikeRow(entry: entry) {
                            store.open(entry)
                            dismiss()
                        }
                        .contextMenu {
                            Button("Open") {
                                store.open(entry)
                                dismiss()
                            }
                            Button("Show in Finder") { store.reveal(entry) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { store.delete(entry) }
                        }
                        if entry.id != captures.last?.id { Divider().padding(.leading, 44) }
                    }
                }
            }
            .frame(height: min(CGFloat(captures.count) * 74, 370))
        } else {
            Text(store.captures == nil ? "Reading captures…" : "No spikes captured yet.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    /// "3 captures · 412 KB · newest 20 kept".
    private var footer: String {
        let captures = store.captures ?? []
        let bytes = captures.reduce(Int64(0)) { $0 + $1.bytes }
        let count = captures.count == 1 ? "1 capture" : "\(captures.count) captures"
        return captures.isEmpty ? "Newest \(store.library.keptCount) kept"
            : "\(count) · \(Format.bytes(UInt64(max(bytes, 0)))) · newest \(store.library.keptCount) kept"
    }
}

/// One capture in the list: what crossed, when and for how long, and the
/// busiest processes. Clicking it opens the capture.
struct HistorySpikeRow: View {
    let entry: SpikeCaptureEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: HistorySpikeStyle.symbol(incident?.kind))
                    .font(.title3)
                    .foregroundStyle(HistorySpikeStyle.color(incident?.kind))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.tableText)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(when)
                        .font(.tableText)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                    if let busiest = incident.flatMap({ HistorySpikeStyle.contributors($0) }) {
                        Text(busiest)
                            .font(.explanation)
                            .foregroundStyle(.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var incident: SpikeIncident? { entry.incident }

    private var title: String {
        incident?.headline ?? (entry.session.note.isEmpty ? entry.url.deletingPathExtension().lastPathComponent : entry.session.note)
    }

    /// "Oct 7, 10:02:14 AM · 3 min captured · also memory pressure".
    private var when: String {
        let start = incident?.start ?? entry.session.start
        var parts = [start.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()),
                     "\(Format.roughDuration(entry.session.duration)) captured"]
        if let others = incident?.triggers.dropFirst(), !others.isEmpty {
            parts.append("also " + others.map { $0.kind.label.lowercased() }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        var lines = [title]
        if let incident {
            lines += incident.triggers.map { "\($0.kind.label): \($0.summary) at \($0.time.formatted(date: .omitted, time: .standard))" }
            let busiest = HistorySpikeStyle.contributorLines(incident)
            if !busiest.isEmpty { lines += ["", busiest] }
        }
        lines += ["", entry.url.lastPathComponent, "Click to open it on the History page."]
        return lines.joined(separator: "\n")
    }
}

/// Under the replay banner's title for a spike capture: what crossed, when,
/// and the busiest processes.
struct HistorySpikeIncidentLine: View {
    let incident: SpikeIncident

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondaryText)
            .lineLimit(2)
            .help(([text, ""] + [HistorySpikeStyle.contributorLines(incident)]).joined(separator: "\n"))
    }

    /// "Crossed at 10:02:14: 97% of the whole CPU for 10 s · then Disk 412 MB/s
    /// for 10 s, usually 2.1 MB/s · busiest yes 48%, … of the CPU time".
    private var text: String {
        let primary = incident.primary
        var parts = ["Crossed at \(primary.time.formatted(date: .omitted, time: .standard)): \(Self.phrase(primary))"]
        parts += incident.triggers.dropFirst().map { "then " + Self.phrase($0) }
        if let busiest = HistorySpikeStyle.contributors(incident) { parts.append("busiest " + busiest) }
        return parts.joined(separator: " · ")
    }

    /// A trigger's summary, named unless it names itself (the CPU's does).
    private static func phrase(_ trigger: SpikeTrigger) -> String {
        trigger.kind == .cpu ? trigger.summary : "\(trigger.kind.label) \(trigger.summary)"
    }
}

/// Settings' History section: the spike capture switch.
struct SpikeCaptureSettings: View {
    @Bindable private var store = SpikeCaptureStore.shared

    var body: some View {
        Section("History") {
            Toggle("Capture spikes automatically", isOn: $store.isEnabled)
            Text(HistorySpikeStyle.explanation + " Open them from History's Spikes button.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
        }
    }
}
