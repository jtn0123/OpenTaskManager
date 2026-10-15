import OTMKit
import SwiftUI

/// The one-off administrator read behind Connections' Show Hidden Sockets:
/// macOS asks for the password, lsof reads off the main actor, and the last
/// read is kept for the session. Nothing runs again until asked.
@MainActor @Observable
final class HiddenSocketStore {
    static let shared = HiddenSocketStore()

    private(set) var read: PrivilegedSocketRead?
    private(set) var isReading = false
    private(set) var failure: String?
    /// Bumped when a read ends without rows: cancelled at the prompt.
    private(set) var cancellations = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The words macOS shows over its password field.
    static let prompt = "OpenTaskManager wants to list the network sockets of every process, once."

    func readAgain() {
        guard !isReading else { return }
        isReading = true
        failure = nil
        task = Task {
            let outcome = await PrivilegedSocketReader.read(prompt: Self.prompt)
            isReading = false
            task = nil
            switch outcome {
            case let .read(read): self.read = read
            case .cancelled: cancellations += 1
            case let .failed(message): failure = message
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// Every process's sockets from one administrator read: by default only the
/// processes the page leaves out, with the page's counts above them.
struct HiddenSocketsSheet: View {
    private let store = HiddenSocketStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showsEveryone = false
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\PrivilegedSocketRead.Row.processName)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hidden Sockets").font(.title2.weight(.semibold))
                Spacer()
                Button("Read Again") { store.readAgain() }
                    .disabled(store.isReading)
                    .help("Ask for an administrator's password and read every process's sockets again")
                Button("Done") {
                    store.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Text(caption).font(.explanation).foregroundStyle(.secondaryText)
            if let failure = store.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.explanation)
                    .foregroundStyle(Theme.network)
            }
            if let read = store.read {
                results(read)
            } else {
                waiting
            }
        }
        .padding(20)
        .frame(width: 960, height: 580)
        .onAppear {
            if store.read == nil { store.readAgain() }
        }
        // Cancelled at the prompt with nothing read yet: nothing to show.
        .onChange(of: store.cancellations) {
            if store.read == nil { dismiss() }
        }
    }

    private var caption: String {
        if let read = store.read {
            let time = read.readAt.formatted(date: .omitted, time: .shortened)
            return "Read with an administrator's password at \(time). It doesn't update, and nothing keeps running as root."
        }
        return "macOS asks for an administrator's password in its own window, then lsof reads every process's sockets once."
    }

    @ViewBuilder private var waiting: some View {
        VStack(spacing: 10) {
            if store.isReading {
                ProgressView()
                Text("Waiting for an administrator's password…").font(.explanation).foregroundStyle(.secondaryText)
            } else {
                Button("Try Again") { store.readAgain() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ read: PrivilegedSocketRead) -> some View {
        let others = read.rows(notRunningAs: NSUserName())
        let listed = (showsEveryone ? read.rows : others).filter { $0.matches(search) }.sorted(using: sortOrder)
        let summary = ConnectionSummary(listed.map(\.connection))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Show", selection: $showsEveryone) {
                    Text("Other accounts (\(others.count.formatted()))").tag(false)
                    Text("Everyone (\(read.rows.count.formatted()))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Other accounts are the processes the page can't read: root's, system services' and other users'")
                TextField("Process, user, address or port", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer(minLength: 0)
                Text(Self.counts(listed.count, summary))
                    .font(.metadata).foregroundStyle(.secondaryText).monospacedDigit()
                    .lineLimit(1)
            }
            Table(listed, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.processName) { row in
                    Text(row.processName).lineLimit(1).help(row.processName)
                }
                .width(min: 90, ideal: 126)
                TableColumn("PID", value: \.pid) { row in
                    Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondaryText)
                }
                .width(min: 36, ideal: 44)
                TableColumn("User", value: \.user) { row in
                    Text(row.user).lineLimit(1)
                }
                .width(min: 60, ideal: 102)
                TableColumn("Protocol", value: \.protocolLabel) { row in
                    Text(row.protocolLabel)
                }
                .width(min: 60, ideal: 70)
                TableColumn("Local", value: \.localText) { row in
                    Text(row.localText).lineLimit(1).truncationMode(.middle).monospacedDigit()
                }
                .width(min: 70, ideal: 98)
                TableColumn("Remote", value: \.remoteText) { row in
                    Text(row.remoteText).lineLimit(1).truncationMode(.middle).monospacedDigit()
                }
                .width(min: 70, ideal: 114)
                TableColumn("State", value: \.stateRank) { row in
                    Text(row.connection.stateLabel).foregroundStyle(row.connection.kind.tint)
                }
                .width(min: 60, ideal: 76)
                TableColumn("Scope", value: \.scopeLabel) { row in
                    ScopeLabel(connection: row.connection)
                }
                .width(min: 80, ideal: 110)
            }
            .font(.tableText)
            .overlay {
                if listed.isEmpty {
                    Text(search.isEmpty ? "No sockets" : "No sockets match “\(search)”")
                        .font(.explanation).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    /// "212 sockets · 63 processes · 9 exposed ports".
    static func counts(_ sockets: Int, _ summary: ConnectionSummary) -> String {
        var parts = ["\(sockets.formatted()) \(sockets == 1 ? "socket" : "sockets")",
                     "\(summary.processesWithSockets.formatted()) \(summary.processesWithSockets == 1 ? "process" : "processes")"]
        if summary.exposedPorts > 0 {
            parts.append("\(summary.exposedPorts.formatted()) exposed \(summary.exposedPorts == 1 ? "port" : "ports")")
        }
        return parts.joined(separator: " · ")
    }
}

/// The figures the sheet's columns sort and search by.
extension PrivilegedSocketRead.Row {
    var processName: String { connection.processName }
    var pid: Int32 { connection.pid }
    var protocolLabel: String { "\(connection.transport.rawValue) \(connection.family.shortLabel)" }
    var localText: String { connection.local.formatted }
    var remoteText: String { connection.remote?.formatted ?? "—" }
    var stateRank: Int { connection.kind.rank }
    var scopeLabel: String { connection.scope.label }

    func matches(_ search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [processName, user, String(pid), localText, remoteText].contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
