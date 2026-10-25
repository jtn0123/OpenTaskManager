import OTMKit
import SwiftUI

/// Paths, current figures and warnings stay visible before anything moves, like the Apps review.
struct StorageCleanupSheet: View {
    @Bindable var model: StorageCleanupModel
    let store: StorageStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.execution == nil ? "Review Cleanup" : "Cleanup Results").font(.title2.weight(.semibold))
            Text("Move the selected items to the Trash, where you can put them back. Nothing is permanently deleted here.")
                .font(.explanation).foregroundStyle(.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let execution = model.execution {
                        results(execution)
                    } else {
                        ForEach(model.items) { item in reviewRow(item) }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 100, maxHeight: 420)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            Text(model.summary).font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
            HStack {
                Spacer()
                if model.moving {
                    ProgressView().controlSize(.small)
                    Text("Moving to the Trash…").font(.metadata).foregroundStyle(.secondaryText)
                } else if model.execution != nil {
                    Button("Rescan") {
                        store.scan(model.scope)
                        dismiss()
                    }
                    .help("Scan the affected folder again when you're ready")
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Move \(model.selectedCount) \(model.selectedCount == 1 ? "Item" : "Items") to Trash", role: .destructive) {
                        Task { await model.move() }
                    }
                    .disabled(model.selectedCount == 0)
                }
            }
        }
        .padding(20)
        .frame(width: 660)
        .interactiveDismissDisabled(model.moving)
    }

    private func reviewRow(_ item: StorageCleanupItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Move \((item.id as NSString).lastPathComponent) to Trash", isOn: Binding(
                get: { model.selection.contains(item.id) },
                set: { selected in
                    if selected { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(item.refusal != nil || model.moving)
            VStack(alignment: .leading, spacing: 4) {
                Text((item.id as NSString).lastPathComponent).font(.tableText.weight(.medium))
                path(item.id)
                ForEach(StorageCleanupText.sizes(item), id: \.self) { line in
                    Text(line).font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                }
                Text(stateText(item)).font(.explanation).foregroundStyle(.secondaryText)
                if let included = item.includesText { Text(included).font(.explanation).foregroundStyle(.secondaryText) }
                if let refusal = item.refusal {
                    Label("Not offered: " + refusal, systemImage: "lock.fill").font(.explanation).foregroundStyle(.red)
                }
                ForEach(item.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.explanation).foregroundStyle(Theme.network)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stateText(_ item: StorageCleanupItem) -> String {
        let state = item.state
        let kind = state.isFolder ? "Folder · " + (state.itemCount.map { "\($0.formatted()) items" } ?? "item count not measured") : "File"
        let readable = state.readable ? "readable" : "not readable"
        let volume = state.local ? "local volume" : "local volume not verified"
        let date = state.modified.map { " · Modified " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return "\(kind) · \(readable) · \(volume)" + date
    }

    private func path(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CopyableText(value: value, truncatesMiddle: true).font(.tableText).foregroundStyle(.secondaryText)
            HStack {
                Button("Reveal in Finder") { store.reveal(value) }
                Button("Copy Path") { store.copyPath(value) }
            }
            .linkButtonStyle().font(.explanation)
        }
    }

    private func results(_ execution: StorageCleanupExecution) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(execution.outcomes) { outcome in
                VStack(alignment: .leading, spacing: 4) {
                    Text((outcome.path as NSString).lastPathComponent).font(.tableText.weight(.medium))
                    path(outcome.path)
                    Text(resultText(outcome.result)).font(.explanation)
                        .foregroundStyle(outcome.result.succeeded ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(Color.red))
                }
            }
            Divider()
            ForEach(execution.measurements) { measurement in
                VStack(alignment: .leading, spacing: 3) {
                    Text(measurement.text).font(.tableText).monospacedDigit()
                    Text(measurement.volume).font(.metadata).foregroundStyle(.secondaryText)
                }
            }
            Text("Measured before and after the move. Other disk activity can change this figure; moving to the Trash may keep blocks in use.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
    }

    private func resultText(_ result: RemovalResult) -> String {
        switch result {
        case .moved: "Moved to the Trash"
        case let .failed(reason): "Not moved: \(reason)"
        case let .skipped(reason): "Not moved: \(reason)"
        }
    }
}
