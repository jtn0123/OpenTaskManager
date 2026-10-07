import OTMKit
import SwiftUI

/// The pane beside the Drivers table: what the selected extension is, where
/// it came from, and for a kext, what it links against and what uses it.
struct DriverDetail: View {
    /// Links beyond this many are counted rather than listed.
    private static let linkLimit = 10

    var item: ExtensionItem
    var scan: ExtensionScan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if item.status.needsAttention { approvalNote }
                    facts
                    Text(about)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    labelled("Bundle ID", item.bundleID)
                    if let system = item.systemExtension { systemDetails(system) }
                    if let kext = item.kernelExtension { kernelDetails(kext) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
        .padding(12)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            ExtensionIcon(item: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(2)
                Text(item.kind).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
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

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Status").foregroundStyle(.secondaryText)
                ExtensionStatusLabel(status: item.status)
            }
            .font(.callout)
            FactRow(label: "Publisher", value: item.publisher.title)
            FactRow(label: "Version", value: version)
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

    @ViewBuilder
    private func systemDetails(_ system: SystemExtension) -> some View {
        if let team = system.teamID { labelled("Team ID", team) }
        if let app = system.appPath {
            VStack(alignment: .leading, spacing: 4) {
                labelled("Installed by", app)
                if let path = DriverActions.revealablePath(item) {
                    Button("Reveal in Finder") { DriverActions.reveal(path) }
                        .controlSize(.small)
                }
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Reported as").font(.subheadline).foregroundStyle(.secondaryText)
            Text(verbatim: system.state)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
        }
        .help("systemextensionsctl's own words for this extension's state")
        if let location = system.settingsLocation {
            Text("Change it in \(location).")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func kernelDetails(_ kext: KernelExtension) -> some View {
        if let uuid = kext.uuid { labelled("UUID", uuid) }
        if let path = kext.path { labelled("Path", path) }
        if let address = kext.loadAddress {
            labelled("Load address", "0x" + String(address, radix: 16))
        }
        links("Links against", scan.linkedAgainst(kext))
        links("Used by", scan.linkedBy(kext))
    }

    /// One button, so it always fits the pane: System Settings for a system
    /// extension (its app is revealed beside its path), Finder for a kext.
    @ViewBuilder
    private var buttons: some View {
        if item.systemExtension != nil {
            Button("Open Login Items & Extensions Settings") { DriverActions.openSettings() }
                .help("System Settings > General > Login Items & Extensions, where system extensions are allowed and turned off")
        } else if let path = DriverActions.revealablePath(item) {
            Button("Reveal in Finder") { DriverActions.reveal(path) }
        }
    }

    // MARK: Text

    private var version: String {
        let build = item.systemExtension?.build
        switch (item.version.isEmpty ? nil : item.version, build) {
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
                Text("\(title) (\(bundleIDs.count))").font(.subheadline).foregroundStyle(.secondaryText)
                ForEach(bundleIDs.prefix(Self.linkLimit), id: \.self) { bundleID in
                    Text(bundleID)
                        .font(.subheadline.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(bundleID)
                }
                if bundleIDs.count > Self.linkLimit {
                    Text("and \(bundleIDs.count - Self.linkLimit) more")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondaryText)
            CopyableText(value: value).font(.subheadline)
        }
    }
}
