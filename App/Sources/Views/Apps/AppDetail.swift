import OTMKit
import SwiftUI

/// The pane beside the Apps table: everything read about one app, who
/// signed it, and the launchd jobs it brought with it.
struct AppDetail: View {
    var app: InstalledApp
    var size: UInt64?
    var isMeasuring: Bool
    var pids: [Int32]
    /// Opens the Startup page on this app's launch items.
    var showInStartup: () -> Void
    /// Opens the removal review; nil for apps it isn't offered for.
    var moveToTrash: (() -> Void)?

    /// Folded at first, and left as it is while the selection moves.
    @State private var showsCertificates = false

    /// Who the app is stays at the top and what can be done with it in a
    /// footer, and everything read about it scrolls between them, in the
    /// pane's only scroll view. Paths keep to one line and the certificate
    /// chain folds away, so nothing needs a scroll view of its own.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView { details.padding(12) }
            Divider()
            actions.padding(12)
        }
    }

    // MARK: Sections

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let warning = ArchitectureWarning(app.architecture) { warning }
            facts
            labelled("Location", app.path)
            if AppDetail.differs(app.resolvedPath, from: app.path) {
                labelled("Links to", app.resolvedPath)
            }
            Divider()
            launchItems
            Divider()
            signature
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forBundle: app.path))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(2)
                if let identifier = app.bundleIdentifier {
                    Text(identifier)
                        .font(.subheadline.monospaced()).foregroundStyle(.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(identifier)
                }
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            FactRow(label: "Version", value: app.versionText)
            FactRow(label: "Kind", value: app.isiOSApp ? "\(app.kind.title), iPhone and iPad app" : app.kind.title)
            FactRow(label: "Architecture", value: architecture)
            FactRow(label: "Size", value: size.map(Format.bytes) ?? (isMeasuring ? "Measuring…" : "—"))
            FactRow(label: "Last opened", value: app.lastOpened.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
            if let added = app.added {
                FactRow(label: "Added", value: added.formatted(date: .abbreviated, time: .shortened))
            }
            FactRow(label: "Running", value: running)
            if let minimum = app.minimumSystemVersion {
                FactRow(label: "Needs", value: "\(app.isiOSApp ? "iOS" : "macOS") \(minimum) or later")
            }
        }
    }

    private var signature: some View {
        let signature = app.signature
        return VStack(alignment: .leading, spacing: 8) {
            Text("Signature").font(.subheadline.weight(.semibold)).foregroundStyle(.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                FactRow(label: "Signed by", value: signature.signer.title)
                if let developer = signature.developerName {
                    FactRow(label: "Developer", value: developer)
                }
                if let team = signature.teamIdentifier {
                    FactRow(label: "Team ID", value: team)
                }
                // Apple's own apps are platform binaries, protected without the hardened runtime flag.
                if ![.apple, .unsigned, .unknown].contains(signature.signer) {
                    FactRow(label: "Hardened runtime", value: signature.hardenedRuntime ? "Yes" : "No")
                }
            }
            Text(signature.signer.explanation).font(.subheadline).foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let identifier = signature.identifier, identifier != app.bundleIdentifier {
                labelled("Signing identifier", identifier)
            }
            if !signature.authorities.isEmpty {
                DetailDisclosure("Certificate chain", preview: signature.authorities.joined(separator: " › "),
                                 isExpanded: $showsCertificates) {
                    certificateChain(signature.authorities)
                }
            }
            Text("Notarization isn't shown: checking it means validating the whole bundle with Gatekeeper.")
                .font(.subheadline).foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Signing certificate first, each issuer indented under the one it signed.
    private func certificateChain(_ authorities: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(authorities.enumerated()), id: \.offset) { depth, authority in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .imageScale(.small)
                            .foregroundStyle(.secondaryText)
                    }
                    Text(authority).font(.subheadline).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(max(depth - 1, 0)) * 12)
            }
        }
    }

    private var launchItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch items").font(.subheadline.weight(.semibold)).foregroundStyle(.secondaryText)
            if app.launchItems.isEmpty {
                Text("None: nothing in the LaunchAgents or LaunchDaemons folders runs from this app or carries its bundle ID.")
                    .font(.subheadline).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(app.launchItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(item.state.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                .help(item.label)
                            Text("\(item.scope.title) · \(item.launchSummary) · \(item.state.title)")
                                .font(.subheadline).foregroundStyle(.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                Text(startsItselfNote).font(.subheadline).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Button { AppActions.open(app) } label: { Text("Open").frame(maxWidth: .infinity) }
                Button { AppActions.reveal(app) } label: { Text("Reveal in Finder").frame(maxWidth: .infinity) }
            }
            GridRow {
                Button(action: showInStartup) { Text("Show in Startup").frame(maxWidth: .infinity) }
                    .disabled(app.launchItems.isEmpty)
                    .help(app.launchItems.isEmpty ? "This app has no launch items" : "Open the Startup page on this app's launch items")
                Button { AppActions.copy(app.bundleIdentifier ?? "") } label: { Text("Copy Bundle ID").frame(maxWidth: .infinity) }
                    .disabled(app.bundleIdentifier == nil)
            }
            // A row of its own, apart from the everyday actions, and red
            // because it ends in the Trash (after a review).
            if let moveToTrash {
                GridRow {
                    Button(role: .destructive, action: moveToTrash) {
                        Label("Move to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.red)
                    .gridCellColumns(2)
                    .help("Review the app and what it keeps in your Library, then move them to the Trash")
                }
            }
        }
    }

    // MARK: Text

    private var architecture: String {
        guard let names = app.sliceNames else { return app.architecture.title }
        return "\(app.architecture.title) (\(names))"
    }

    private var running: String {
        switch pids.count {
        case 0: "No"
        case 1: "PID \(pids[0])"
        default: "PIDs " + pids.map(String.init).joined(separator: ", ")
        }
    }

    private var startsItselfNote: String {
        let starting = app.selfStartingItems.count
        let total = app.launchItems.count
        if starting == 0 { return total == 1 ? "It only runs when something asks for it." : "They only run when something asks for them." }
        if starting == total { return total == 1 ? "It starts by itself." : "All of them start by themselves." }
        return "\(starting) of \(total) start by themselves; the rest run when something asks for them."
    }

    /// Whether resolving links changed more than the /System/Volumes/Data prefix.
    private static func differs(_ resolved: String, from path: String) -> Bool {
        InstalledApps.normalized(resolved) != InstalledApps.normalized(path)
    }

    /// A path or identifier keeps to one line, cut in the middle, with the
    /// whole of it in a tooltip and a copy button.
    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondaryText)
            CopyableText(value: value, truncatesMiddle: true).font(.subheadline)
        }
    }
}

/// A banner for apps that need Rosetta or can't run at all.
private struct ArchitectureWarning: View {
    var title: String
    var detail: String
    var color: Color

    init?(_ architecture: AppArchitecture) {
        switch architecture {
        case .intel:
            title = "Intel only — runs under Rosetta"
            detail = "Rosetta translates it as it starts, which costs some speed and battery. "
                + "Apple plans to keep Rosetta for all Intel apps only through macOS 27."
            color = Theme.network
        case .unsupported:
            title = "Can't run on this Mac"
            detail = "It's built only for 32-bit or PowerPC processors, which current macOS doesn't support."
            color = .red
        case .appleSilicon, .universal, .unknown:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                // Wraps without `fixedSize`: when the banner sat above the
                // details' scroll view, a fixed-height text here made the split
                // view size the page from the pane and push the status bar out
                // of the window.
                Text(detail).font(.subheadline).foregroundStyle(.secondaryText)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.4), lineWidth: 0.75))
    }
}
