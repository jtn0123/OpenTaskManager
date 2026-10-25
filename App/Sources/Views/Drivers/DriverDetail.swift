import OTMKit
import SwiftUI

/// The pane beside the Drivers table: what the selected extension is, where
/// it came from (its app and its copy on disk), and for a kext, what it links
/// against and what uses it.
struct DriverDetail: View {
    /// Links beyond this many are counted rather than listed.
    private static let linkLimit = 10

    var item: ExtensionItem
    var scan: ExtensionScan

    /// Like the Startup and Apps panes: the extension, with the row's icon
    /// and name, pinned at the top, the action in a footer, and everything
    /// read about it scrolling between them, edge to edge.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if item.status.needsAttention { approvalNote }
                    facts
                    if item.status.isDiskCopy { diskCopyNote }
                    Text(about)
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.bundleID.isEmpty {
                        labelledNote("Bundle ID", "Couldn't be read from its Info.plist")
                    } else {
                        labelled("Bundle ID", item.bundleID)
                    }
                    if let team = item.teamID { labelled("Team ID", team) }
                    location
                    if let system = item.systemExtension { systemDetails(system) }
                    if let kext = item.kernelExtension { kernelDetails(kext) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            if hasAction {
                Divider()
                buttons
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            ExtensionIcon(item: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(2)
                Text(item.kind).font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
            }
        }
    }

    private var approvalNote: some View {
        Label {
            Text("Waiting for your approval. Allow it in System Settings, under Login Items & Extensions, or remove the app that installed it.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Why a copy on disk isn't in use, or why that's unknown. Informative,
    /// not a warning: a copy that doesn't run isn't a problem.
    private var diskCopyNote: some View {
        Label {
            Text(item.statusExplanation)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondaryText)
        }
        .font(.explanation)
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Status").foregroundStyle(.secondaryText)
                ExtensionStatusLabel(status: item.status)
            }
            .font(.callout)
            FactRow(label: "Publisher", value: item.publisher.title)
            FactRow(label: "Version", value: version)
            if let bundle = item.bundle {
                FactRow(label: "Signature", value: bundle.signer.title)
                    .help(bundle.signer.explanation)
            }
            if let kext = item.kernelExtension {
                // Verbatim, so the tag isn't grouped like a quantity ("1,234").
                GridRow {
                    Text("Load tag").foregroundStyle(.secondaryText)
                    Text(verbatim: "\(kext.loadTag)").textSelection(.enabled)
                }
                .font(.callout)
                if !kext.isInterface {
                    FactRow(label: "Memory", value: memory(kext))
                }
            }
        }
    }

    /// The app it came with, by icon and name, and its copy on disk. A
    /// system extension's footer holds System Settings, so its Reveal in
    /// Finder and Copy Path sit here; a kext's are in the footer.
    @ViewBuilder
    private var location: some View {
        let copy = item.bundle?.path
        // A loaded kext's own path already shows under its kernel details.
        let showsCopy = copy != nil && copy != item.kernelExtension?.path
        if item.appPath != nil || showsCopy {
            VStack(alignment: .leading, spacing: 10) {
                if let app = item.appPath { owner(app) }
                if showsCopy, let copy { pathField("On disk", copy) }
                if item.systemExtension != nil, let path = DriverActions.revealablePath(item) {
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { DriverActions.reveal(path) }
                        Button("Copy Path") { DriverActions.copy(path) }
                            .help(copy == nil ? "Copy the installing app's whole path" : "Copy the extension's whole path")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// The app's icon and name, its whole path in the tooltip.
    private func owner(_ app: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.systemExtension?.appPath != nil ? "Installed by" : "Comes with")
                .font(.callout)
                .foregroundStyle(.secondaryText)
            HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(forBundle: app))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(Extensions.appName(app))
                    .font(.callout)
                    .lineLimit(2)
            }
            .help(app)
        }
    }

    @ViewBuilder
    private func systemDetails(_ system: SystemExtension) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reported as").font(.callout).foregroundStyle(.secondaryText)
            Text(verbatim: system.state)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .help("systemextensionsctl's own words for this extension's state")
        if let location = system.settingsLocation {
            Text("Change it in \(location).")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func kernelDetails(_ kext: KernelExtension) -> some View {
        if let uuid = kext.uuid { labelled("UUID", uuid, oneLine: true) }
        if let path = kext.path { pathField("Path", path) }
        if let address = kext.loadAddress {
            labelled("Load address", "0x" + String(address, radix: 16))
        }
        links("Links against", scan.linkedAgainst(kext))
        links("Used by", scan.linkedBy(kext))
    }

    /// Whether the footer has a button: a kext no longer on disk has none.
    private var hasAction: Bool {
        item.systemExtension != nil || DriverActions.revealablePath(item) != nil
    }

    /// What fits the pane: System Settings for a system extension (its copy
    /// or app is revealed and copied beside its path), Finder and the path
    /// for a kext or a copy on disk that macOS doesn't report.
    @ViewBuilder
    private var buttons: some View {
        if item.systemExtension != nil {
            Button("Open Login Items & Extensions Settings") { DriverActions.openSettings() }
                .help("System Settings > General > Login Items & Extensions, where system extensions are allowed and turned off")
        } else if let path = DriverActions.revealablePath(item) {
            HStack(spacing: 8) {
                Button("Reveal in Finder") { DriverActions.reveal(path) }
                    .help(item.appPath == nil ? "Show the extension in Finder" : "Show the extension in Finder, inside its app")
                Button("Copy Path") { DriverActions.copy(path) }
                    .help("Copy the extension's whole path")
            }
        }
    }

    // MARK: Text

    /// The short version with the build beside it where they differ: from
    /// systemextensionsctl, or from the Info.plist of a copy on disk. A loaded
    /// kext has only the one the kernel gives.
    private var version: String {
        let short: String?
        let build: String?
        if let system = item.systemExtension {
            (short, build) = (system.version, system.build)
        } else if item.kernelExtension == nil, let bundle = item.bundle {
            (short, build) = (bundle.version, bundle.build)
        } else {
            (short, build) = (item.version.isEmpty ? nil : item.version, nil)
        }
        switch (short, build) {
        case let (version?, build?) where build != version: return "\(version) (\(build))"
        case let (version?, _): return version
        case let (nil, build?): return build
        case (nil, nil): return "—"
        }
    }

    /// What this kind of extension does, in a sentence or two.
    private var about: String {
        switch item.category {
        case .network:
            "Sees or steers network traffic, as VPNs, firewalls and content filters do. It runs as its own process, outside the kernel."
        case .driver:
            "Drives a device from outside the kernel with DriverKit, so if it crashes, the Mac keeps running."
        case .endpointSecurity:
            "Watches what happens on the Mac, such as programs starting and files opening, on behalf of security software."
        case .otherSystem:
            "A system extension: it runs as its own process, outside the kernel, with rights an app alone doesn't get."
        case .kernel where item.isKernelInterface:
            "Part of the kernel itself: a set of functions other kernel extensions link against. It has no code of its own to load."
        case .kernel where item.publisher == .apple:
            "Part of macOS. It runs inside the kernel, loaded at startup or when the hardware or feature it serves needs it."
        case .kernel:
            "Runs inside the kernel with full access to the Mac. macOS only loads one from another developer after you allow it."
        }
    }

    private func memory(_ kext: KernelExtension) -> String {
        kext.wiredSize == kext.size || kext.size == 0
            ? "\(Format.bytes(kext.wiredSize)) wired"
            : "\(Format.bytes(kext.wiredSize)) wired of \(Format.bytes(kext.size))"
    }

    // MARK: Parts

    @ViewBuilder
    private func links(_ title: String, _ bundleIDs: [String]) -> some View {
        if !bundleIDs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) (\(bundleIDs.count))").font(.callout).foregroundStyle(.secondaryText)
                ForEach(bundleIDs.prefix(Self.linkLimit), id: \.self) { bundleID in
                    Text(bundleID)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(bundleID)
                }
                if bundleIDs.count > Self.linkLimit {
                    Text("and \(bundleIDs.count - Self.linkLimit) more")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
    }

    /// `oneLine` for the UUID: cut in the middle, whole in the tooltip and
    /// when copied, where wrapping left a lone character on a line of its
    /// own in a narrow pane.
    private func labelled(_ label: String, _ value: String, oneLine: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondaryText)
            CopyableText(value: value, truncatesMiddle: oneLine).font(.callout)
        }
    }

    /// A label over a sentence saying why its value is missing.
    private func labelledNote(_ label: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondaryText)
            Text(note).font(.explanation).foregroundStyle(.secondaryText)
        }
    }

    /// A path's name over its folder, which wraps, so the folders that tell
    /// two copies apart are never cut out.
    private func pathField(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondaryText)
            CopyableText(value: path, splitsPath: true).font(.callout)
        }
    }
}
