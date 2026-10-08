import AppKit
import OTMKit
import SwiftUI

/// An inventory requested by the user, held until another search. This view
/// observes no sampler figures and does no work on a sampler tick.
struct FindOwnerSheet: View {
    var initialQuery: String
    var onSelect: (ProcessIdentity) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var result: OwnerLookupResult?
    @State private var error: String?
    @State private var selectionNote: String?
    @State private var isSearching = false
    @State private var request: String?
    @State private var revision = 0
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Owner").font(.title2).fontWeight(.semibold)
            Text("Find which processes hold a file, folder or local port. You can also drop a file here.")
                .font(.explanation).foregroundStyle(.secondaryText)
            HStack {
                TextField("Path or port (tcp:8080, udp:5353)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit(search)
                    .disabled(isSearching)
                Button("Choose…", action: choose).disabled(isSearching)
                Button("Search", action: search)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if let result {
                    Text("\(result.processes.count) matching processes · \(Format.fixed(result.duration * 1_000, 1) + " ms")")
                        .font(.metadata).foregroundStyle(.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
        .dropDestination(for: URL.self) { urls, _ in
            guard !isSearching, let url = urls.first, url.isFileURL else { return false }
            query = url.path
            search()
            return true
        }
        .onAppear {
            query = initialQuery
            queryFocused = true
            if !initialQuery.isEmpty { search() }
        }
        .task(id: revision) {
            guard let request else { return }
            do {
                let found = try await Task.detached(priority: .userInitiated) { try OwnerLookup.search(request) }.value
                guard !Task.isCancelled else { return }
                result = found
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isSearching = false
        }
    }

    @ViewBuilder private var results: some View {
        if isSearching {
            ProgressView("Checking processes…")
        } else if let error {
            Text(error).font(.explanation).foregroundStyle(.secondaryText).textSelection(.enabled)
        } else if let result {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if result.processes.isEmpty {
                            Text(result.emptyDescription).font(.explanation).foregroundStyle(.secondaryText)
                                .textSelection(.enabled)
                        }
                        ForEach(result.processes) { process in
                            processRow(process)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let selectionNote {
                    Text(selectionNote).font(.explanation).foregroundStyle(.secondaryText)
                }
                Text(result.unreadableDescription)
                    .font(.explanation).foregroundStyle(.secondaryText)
                if let note = result.target.volumeNote {
                    Text(note).font(.explanation).foregroundStyle(.secondaryText)
                }
            }
        } else {
            Text("Search checks open file descriptors, current directories for folders, or TCP and UDP sockets for a local port.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
    }

    private func processRow(_ process: OwnerProcess) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { select(process) } label: {
                HStack {
                    Text(process.name).fontWeight(.semibold)
                    Text("PID \(String(process.identity.pid)) · \(process.user)").foregroundStyle(.secondaryText)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select this process in the Processes table; available while the same process is still running.")
            if let path = process.path {
                Text(path).font(.metadata).foregroundStyle(.secondaryText).textSelection(.enabled)
            }
            ForEach(process.matches.indices, id: \.self) { index in
                Button { select(process) } label: {
                    Text(process.matches[index].label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select this process in the Processes table")
            }
        }
        .font(.tableText)
    }

    private func select(_ process: OwnerProcess) {
        if !onSelect(process.identity) { selectionNote = "This process has ended. Search again to check the current owners." }
    }

    private func search() {
        guard !isSearching, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        result = nil
        selectionNote = nil
        error = nil
        request = query
        isSearching = true
        revision += 1
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file, folder or volume to find which processes hold it open."
        panel.prompt = "Find Owner"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            query = url.path
            search()
        }
    }
}
