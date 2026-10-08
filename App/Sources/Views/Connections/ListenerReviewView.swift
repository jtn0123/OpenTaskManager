import OTMKit
import SwiftUI

/// The entry shares the summary strip's space and observes only settled review changes.
struct ListenerReviewEntry: View {
    private let store = ConnectionStore.shared
    var compact: Bool
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            if compact {
                Label(ListenerReviewWords.changeCount(count), systemImage: "checklist")
                    .font(.explanation)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Theme.disk.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Card(tint: Theme.disk, glow: count > 0 ? 0.35 : 0) {
                    Label("Listeners", systemImage: "checklist")
                        .font(.explanation.weight(.medium)).foregroundStyle(.secondaryText)
                    Spacer(minLength: 0)
                    Text("\(count) \(count == 1 ? "change" : "changes")").font(.title3.weight(.semibold)).monospacedDigit()
                    Text(count == 0 ? ListenerReviewWords.baseline(store.listenerReview) : "since you last reviewed")
                        .font(.metadata).foregroundStyle(.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Review listener changes against the saved baseline. " + ListenerReviewWords.baseline(store.listenerReview))
        .accessibilityLabel("Listeners: " + ListenerReviewWords.changeCount(count) + " since you last reviewed")
    }

    private var count: Int { store.listenerReview?.changes.count ?? 0 }
}

struct ListenerReviewView: View {
    private let store = ConnectionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ListenerChange?
    var showProcess: (Int32) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Listener changes").font(.title2.weight(.semibold))
                Spacer()
                Button("Accept All") { accept(Set(changes.map(\.id))) }
                    .disabled(changes.isEmpty || store.showsListenerFixture || store.acceptingListeners || store.listenerError != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(ListenerReviewWords.baseline(store.listenerReview))
                .font(.explanation).foregroundStyle(.secondaryText)
            Text("TCP listeners and bound UDP sockets seen on two consecutive walks. Accept adds them to your reviewed baseline.")
                .font(.explanation).foregroundStyle(.secondaryText)
            if store.showsListenerFixture {
                Text("Made-up listener changes for screenshots. Nothing is saved.").font(.explanation).foregroundStyle(.secondaryText)
            }
            if store.listenerUnreadable > 0 {
                Text("\(store.listenerUnreadable) processes unreadable. Their listeners are unknown and are outside this review.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
            if let error = store.listenerError {
                Text("Listener review could not be saved or read: " + error).font(.explanation).foregroundStyle(.secondaryText)
            }
            Divider()
            if changes.isEmpty {
                ContentUnavailableView("No listener changes observed", systemImage: "checklist",
                                       description: Text("The saved baseline covers the listeners observed so far."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(changes) { change in
                            changeRow(change)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .sheet(item: $selected) { change in
            ListenerSocketDetail(change: change) { pid in
                selected = nil
                dismiss()
                showProcess(pid)
            }
        }
    }

    private var changes: [ListenerChange] { store.listenerReview?.changes ?? [] }

    private func accept(_ identities: Set<ListenerIdentity>) {
        Task { await store.acceptListeners(identities) }
    }

    private func changeRow(_ change: ListenerChange) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(change.listener.connection.processName).font(.tableText.weight(.semibold))
                Text(change.reasons.map(\.label).joined(separator: " · ")).font(.explanation)
                Text("\(change.id.transport.rawValue) · \(change.id.portLabel(seen: change.listener.connection.local.port)) · \(change.id.scope.label)")
                    .font(.tableText).monospacedDigit()
                CopyableText(value: change.id.executable.path, splitsPath: true)
                if let team = change.id.executable.teamIdentifier {
                    Text("Signing team: " + team).font(.metadata).foregroundStyle(.secondaryText)
                }
                if let identifier = change.id.executable.signingIdentifier {
                    Text("Signing identifier: " + identifier).font(.metadata).foregroundStyle(.secondaryText).textSelection(.enabled)
                }
                ForEach(change.previousHolders, id: \.self) { path in
                    Text("Previously reviewed: " + path).font(.metadata).foregroundStyle(.secondaryText).textSelection(.enabled)
                }
                Text("Observed \(change.detectedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.metadata).foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Button("Socket Details") { selected = change }
                Button("Accept") { accept([change.id]) }
                    .disabled(store.showsListenerFixture || store.acceptingListeners || store.listenerError != nil)
            }
        }
    }
}

/// A retained observation is labelled as such, so an old PID never offers an action on a new process.
private struct ListenerSocketDetail: View {
    private let store = ConnectionStore.shared
    @Environment(\.dismiss) private var dismiss
    let change: ListenerChange
    var showProcess: (Int32) -> Void

    var body: some View {
        let current = store.showsListenerFixture ? nil : store.rows.first {
            $0.connection.id == change.listener.connection.id && $0.connection.process == change.listener.connection.process
        }
        VStack(spacing: 0) {
            HStack {
                Text(current == nil ? "Socket observed at \(ConnectionClock.time(change.detectedAt))" : "Socket open at the latest walk")
                    .font(.explanation).foregroundStyle(.secondaryText)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ConnectionDetail(row: current ?? capturedRow, showProcess: { showProcess(change.listener.connection.pid) }, close: nil)
        }
        .frame(width: 500, height: 460)
    }

    private var capturedRow: ConnectionRow {
        var watch = ConnectionWatch()
        watch.observe([change.listener.connection], at: change.detectedAt)
        // The one socket supplied above always gives one observed row.
        let socket = watch.open[0]
        let process = ConnectionProcess(name: change.listener.connection.processName, path: change.id.executable.path, user: "Not recorded")
        let lifetime = ConnectionLifetime(socket: socket, process: process)
        return ConnectionRow(socket: socket, look: .init(name: process.name, icon: IconCache.generic),
                             at: change.detectedAt, processRunning: false, lifetime: lifetime)
    }
}
