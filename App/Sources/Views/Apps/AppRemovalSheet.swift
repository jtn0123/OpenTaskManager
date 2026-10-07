import OTMKit
import SwiftUI

/// The review before an app goes to the Trash: the bundle, its launch
/// agents and what's named after it in your Library, each with the evidence
/// that ties it to the app. Exact bundle-ID matches start selected; guesses
/// are marked uncertain and start unselected. What needs an administrator is
/// listed but never offered.
struct AppRemovalSheet: View {
    @State private var model: AppRemovalModel
    private let otherApps: [InstalledApp]
    /// Called as the sheet closes if the bundle went to the Trash.
    private let onRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(app: InstalledApp, otherApps: [InstalledApp], onRemoved: @escaping () -> Void) {
        _model = State(initialValue: AppRemovalModel(app: app))
        self.otherApps = otherApps
        self.onRemoved = onRemoved
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 660, maxWidth: 820, minHeight: 420, idealHeight: 660)
        .task {
            await model.load(otherApps: otherApps)
            await model.measureSizes()
        }
        .task { await model.watchRunning() }
        .onDisappear {
            if model.appWasMoved { onRemoved() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.app.path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase == .finished ? "\(model.app.name): what happened" : "Move \(model.app.name) to the Trash?")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .finished:
            "Moved items stay in the Trash until it's emptied, so you can still drag them back out."
        default:
            "Check what goes with it. Items named exactly after its bundle ID start selected; guesses are marked "
                + "uncertain and don't. Everything moves to the Trash, nothing is deleted."
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .finding:
            ProgressView("Looking for what \(model.app.name) keeps in your Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            ScrollView { RemovalResults(model: model).padding(16) }
        case .reviewing, .removing:
            if let plan = model.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let blocker = plan.blocker {
                            RemovalBanner(
                                symbol: "lock.fill", color: .red, title: "OpenTaskManager can't move \(model.app.name)",
                                detail: blocker + " It needs the vendor's uninstaller or an administrator."
                            )
                        }
                        // Only when something runs: an empty banner still takes the stack's spacing.
                        if !model.running.isEmpty { RunningBanner(model: model) }
                        ForEach(groups(plan.items), id: \.location) { group in
                            RemovalSection(title: group.location.title) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    LeftoverRow(model: model, item: item).rowDivider(index > 0)
                                }
                            }
                        }
                        if !plan.protected.isEmpty {
                            RemovalSection(title: "Not offered: needs the vendor's uninstaller or an administrator") {
                                ForEach(Array(plan.protected.enumerated()), id: \.element.id) { index, item in
                                    ProtectedRow(model: model, item: item).rowDivider(index > 0)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func groups(_ items: [LeftoverItem]) -> [(location: LeftoverLocation, items: [LeftoverItem])] {
        Dictionary(grouping: items, by: \.location).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerSummary)
                .font(.metadata)
                .monospacedDigit()
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 8)
            switch model.phase {
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case let .removing(step):
                ProgressView().controlSize(.small)
                Text(step).font(.metadata).foregroundStyle(.secondaryText)
            case .finding, .reviewing:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    Task { await model.remove() }
                } label: {
                    Text(moveTitle)
                }
                .disabled(!model.canRemove)
                .help(moveHelp)
            }
        }
    }

    private var moveTitle: String {
        let count = model.selectedItems.count
        return count == 1 ? "Move 1 Item to Trash" : "Move \(count) Items to Trash"
    }

    private var moveHelp: String {
        if model.plan?.blocker != nil { return "The app needs the vendor's uninstaller or an administrator" }
        if !model.running.isClear { return "Quit the app first" }
        return "Unload its launch agents, then move the selected items to the Trash"
    }

    private var footerSummary: String {
        guard let plan = model.plan else { return "" }
        if model.phase == .finished {
            let moved = model.outcomes.filter(\.result.succeeded).count
            let failed = model.outcomes.count - moved
            return failed == 0 ? "Moved \(moved) of \(moved) to the Trash" : "Moved \(moved), \(failed) not moved"
        }
        let size = Format.bytes(model.selectedBytes)
        return "\(model.selectedItems.count) of \(plan.items.count) selected · \(size)" + (model.isMeasuring ? ", measuring…" : "")
    }
}

// MARK: - Rows

/// A titled group of rows on a rounded panel, like a settings form.
private struct RemovalSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.metadata.weight(.semibold))
                .foregroundStyle(.secondaryText)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

private extension View {
    /// A hairline above every row but a section's first, indented past the checkbox and icon.
    func rowDivider(_ shows: Bool) -> some View {
        overlay(alignment: .top) {
            if shows { Divider().padding(.leading, 62) }
        }
    }
}

private struct LeftoverRow: View {
    @Bindable var model: AppRemovalModel
    var item: LeftoverItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(item.name, isOn: isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.confidence == .required || model.phase != .reviewing)
                .help(item.confidence == .required ? "Goes with the app" : "Move this to the Trash too")
                .padding(.top, 2)
            RemovalIcon(image: model.icons[item.path])
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.tableText.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isUncertain { UncertainTag() }
                    Spacer(minLength: 8)
                    Text(size)
                        .font(.tableText)
                        .monospacedDigit()
                        .foregroundStyle(model.sizes[item.id] == nil ? AnyShapeStyle(Theme.secondaryText)
                            : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        .help(item.location.isMeasured ? "Space it takes on disk"
                            : "macOS asks before one app reads another app's container, so its size isn't measured")
                }
                Text(RemovalText.shortPath(item.path))
                    .font(.metadata.monospaced())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(evidence)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                if let caveat = item.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle.fill")
                        .font(.metadata)
                        .foregroundStyle(Theme.network)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { model.selection.contains(item.id) },
            set: { selected in
                if selected { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
            }
        )
    }

    private var size: String {
        if let bytes = model.sizes[item.id] { return Format.bytes(bytes) }
        if !item.location.isMeasured { return "Not measured" }
        return model.isMeasuring ? "…" : "—"
    }

    private var evidence: String {
        var text = item.evidence.description(bundlePath: model.app.resolvedPath)
        if let agent = item.launchItem {
            text += " · \(agent.state.title)" + (agent.job != nil ? ", unloaded before it moves" : "")
        }
        return text
    }
}

private struct ProtectedRow: View {
    var model: AppRemovalModel
    var item: ProtectedLeftover

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondaryText)
                .frame(width: 14)
                .padding(.top, 2)
            RemovalIcon(image: model.icons[item.path])
            VStack(alignment: .leading, spacing: 2) {
                Text((item.path as NSString).lastPathComponent)
                    .font(.tableText.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RemovalText.shortPath(item.path))
                    .font(.metadata.monospaced())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(item.reason + ". " + item.evidence.description(bundlePath: model.app.resolvedPath))
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct RemovalIcon: View {
    var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct UncertainTag: View {
    var body: some View {
        Text("Uncertain")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.network)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.network.opacity(0.14), in: Capsule())
            .help("Matched by name, team or a shared app group, which doesn't prove the app owns it. Left unselected.")
    }
}

// MARK: - Banners

/// What's running from the app, and the Quit button when it's yours to quit.
private struct RunningBanner: View {
    var model: AppRemovalModel

    var body: some View {
        let running = model.running
        VStack(alignment: .leading, spacing: 8) {
            if !running.needQuitting.isEmpty {
                RemovalBanner(symbol: "exclamationmark.triangle.fill", color: Theme.network, title: quitTitle,
                              detail: "\(list(running.needQuitting)). Quit it before the app moves to the Trash; if it asks to save, "
                                  + "answer it there.") {
                    Button(model.isQuitting ? "Quitting…" : "Quit") { model.quit() }
                        .disabled(model.isQuitting || model.phase != .reviewing)
                }
            }
            if !running.otherUsers.isEmpty {
                RemovalBanner(symbol: "lock.fill", color: .red, title: "Part of it runs as another user",
                              detail: "\(list(running.otherUsers)). Stopping it needs the vendor's uninstaller or an administrator.")
            }
            if !running.stopWithAgent.isEmpty {
                Label("\(list(running.stopWithAgent)) stops when its launch agent is unloaded.", systemImage: "info.circle")
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private var quitTitle: String {
        let main = model.app.executablePath.map(InstalledApps.normalized)
        let mainRuns = model.running.needQuitting.contains { InstalledApps.normalized($0.path) == main }
        return mainRuns ? "\(model.app.name) is running" : "Part of \(model.app.name) is running"
    }

    private func list(_ processes: [BundleProcess]) -> String {
        processes.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
    }
}

private struct RemovalBanner<Accessory: View>: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.metadata).foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.4), lineWidth: 0.75))
    }
}

extension RemovalBanner where Accessory == EmptyView {
    init(symbol: String, color: Color, title: String, detail: String) {
        self.init(symbol: symbol, color: color, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Results

private struct RemovalResults: View {
    var model: AppRemovalModel

    var body: some View {
        RemovalSection(title: "Results") {
            ForEach(Array(model.outcomes.enumerated()), id: \.element.id) { index, outcome in
                HStack(alignment: .top, spacing: 8) {
                    symbol(outcome.result)
                        .frame(width: 14)
                        .padding(.top, 2)
                    RemovalIcon(image: model.icons[outcome.path])
                    VStack(alignment: .leading, spacing: 2) {
                        Text((outcome.path as NSString).lastPathComponent)
                            .font(.tableText.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(RemovalText.shortPath(outcome.path))
                            .font(.metadata.monospaced())
                            .foregroundStyle(.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(outcome.path)
                        Text(message(outcome.result))
                            .font(.metadata)
                            .foregroundStyle(outcome.result.succeeded ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(Color.red))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .rowDivider(index > 0)
            }
        }
    }

    @ViewBuilder private func symbol(_ result: RemovalResult) -> some View {
        switch result {
        case .moved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.disk)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondaryText)
        }
    }

    private func message(_ result: RemovalResult) -> String {
        switch result {
        case let .moved(to): "Moved to the Trash" + (to.isEmpty ? "" : " as \((to as NSString).lastPathComponent)")
        case let .failed(reason): "Not moved: \(reason)"
        case let .skipped(reason): reason
        }
    }
}

enum RemovalText {
    /// The path with your home folder shortened to "~".
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
