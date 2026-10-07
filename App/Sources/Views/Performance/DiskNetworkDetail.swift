import OTMKit
import SwiftUI

struct DiskDetail: View {
    @Environment(AppModel.self) private var model
    /// Bumped by the shortcut beside the title, for the speed test's card.
    @State private var revealTest = 0
    var disk: DiskSample
    var snapshot: SystemSnapshot

    var body: some View {
        let volumes = snapshot.volumes.filter { $0.physicalDisk == disk.bsdName }
        // Only the volumes' names go to the speed test, not their free
        // space, so its card isn't redrawn every tick.
        let choices = volumes.map { DiskSpeedVolumeChoice(name: $0.name, mountPoint: $0.mountPoint, isRoot: $0.isRoot) }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                SpeedTestHeader(title: DiskText.title(disk), subtitle: DiskText.device(disk), action: "Test disk speed…",
                                help: "Go to the disk speed test below. It starts only when you click Run Test.",
                                last: lastTest(choices)) {
                    SpeedTestHeader.scrollToCard(proxy)
                    revealTest += 1
                }
                readings()
                if !volumes.isEmpty {
                    volumeList(volumes)
                }
                DiskSpeedCard(disk: disk.bsdName, volumes: choices, reveal: revealTest)
                    .equatable()
                    .id(SpeedTestHeader.card)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    if let size = disk.size { FactRow(label: "Capacity", value: Format.bytes(size)) }
                    FactRow(label: "Type", value: disk.isDiskImage ? "Disk image"
                        : disk.isSolidState == true ? "SSD" : disk.isSolidState == false ? "Rotational" : "Unknown")
                    if let isInternal = disk.isInternal { FactRow(label: "Location", value: isInternal ? "Internal" : "External") }
                    if let path = disk.imagePath {
                        GridRow {
                            Text("Image file").foregroundStyle(.secondaryText)
                            CopyableText(value: path, monospaced: false, truncatesMiddle: true)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readings() -> some View {
        MetricStrip(tint: Theme.disk) {
            Stat(label: "Read", number: disk.readBytesPerSecond, color: Theme.disk, format: Format.bytesPerSecond)
            Stat(label: "Write", number: disk.writeBytesPerSecond, color: Theme.diskSecondary, format: Format.bytesPerSecond)
            Stat(label: "Active time", number: disk.activeFraction) { Format.percent($0) }
            Stat(label: "IOPS", number: disk.readOperationsPerSecond + disk.writeOperationsPerSecond) { Format.fixed($0, 0) }
            Stat(label: "Read since boot", value: Format.bytes(disk.totalRead))
            Stat(label: "Written since boot", value: Format.bytes(disk.totalWritten))
        }
        // A card, like the network detail's throughput graph.
        ChartCard(title: "Transfer rate", trailing: "read solid, write dashed", tint: Theme.disk) {
            GraphView(series: [
                          GraphSeries(values: model.diskReadHistory[disk.id]?.values ?? [], color: Theme.disk),
                          GraphSeries(values: model.diskWriteHistory[disk.id]?.values ?? [], color: Theme.diskSecondary,
                                      fill: false, dashed: true),
                      ],
                      glows: true, minimumCeiling: 1_048_576, axis: Format.bytesPerSecond, axisUnits: .binaryBytes, cornerRadius: 8)
                .chartFrame(height: DetailGraph.primary, tint: Theme.disk)
        }
        TopAppsCard(title: "Disk I/O", symbol: "internaldrive", color: Theme.disk, groups: model.appGroups,
                    metric: \.diskRate, format: { Format.bytesPerSecond($0.diskRate) }, column: .disk)
    }

    /// The last speed test of the volume a test would use now, or that one is running.
    private func lastTest(_ choices: [DiskSpeedVolumeChoice]) -> String? {
        let store = DiskSpeedStore.shared
        if store.running?.disk == disk.bsdName { return "Testing now…" }
        guard let target = store.target(disk: disk.bsdName, volumes: choices), let result = store.results(for: target).first else {
            return nil
        }
        return "Last: \(Format.megabytesPerSecond(result.sequentialRead.bytesPerSecond)) read, "
            + "\(Format.megabytesPerSecond(result.sequentialWrite.bytesPerSecond)) write · \(Format.ago(-result.date.timeIntervalSinceNow))"
    }

    /// The volumes stored on this disk.
    private func volumeList(_ volumes: [VolumeInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volumes").font(.headline)
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(volume.name)
                        Spacer()
                        Text("\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))")
                            .foregroundStyle(.secondaryText).monospacedDigit()
                    }
                    .font(.callout)
                    let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                    ProgressView(value: used).tint(Theme.pressure(used))
                }
            }
        }
    }
}

/// What the Performance page calls a disk, the same in the list, the chips
/// and the detail: the name people know it by (`DiskSample.name`, the
/// startup volume's or an image's), with its device name ("disk0") after it.
enum DiskText {
    /// "Macintosh HD", or "Disk 4" when nothing names it better.
    static func title(_ disk: DiskSample) -> String {
        disk.name ?? "Disk \(disk.bsdName.replacingOccurrences(of: "disk", with: ""))"
    }

    /// "SSD", "External hard disk", "Disk image"; nil when the disk doesn't say.
    static func kind(_ disk: DiskSample) -> String? {
        if disk.isDiskImage { return "Disk image" }
        guard disk.isInternal == false else { return disk.isSolidState.map { $0 ? "SSD" : "Hard disk" } }
        return disk.isSolidState.map { $0 ? "External SSD" : "External hard disk" } ?? "External"
    }

    /// The list's line under the title: "disk0 · SSD" for a named disk; a
    /// "Disk 4" title has its number already, so its model or kind.
    static func identity(_ disk: DiskSample) -> String {
        guard disk.name != nil else { return model(disk) ?? kind(disk) ?? disk.bsdName }
        return [disk.bsdName, kind(disk)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The detail's subtitle: "disk0 · APPLE SSD AP0512Z", or its kind
    /// where it has no model.
    static func device(_ disk: DiskSample) -> String {
        [disk.bsdName, model(disk) ?? kind(disk)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The disk's model, but not a disk image's "Disk Image", so it reads
    /// as its kind does in the list.
    private static func model(_ disk: DiskSample) -> String? {
        disk.isDiskImage ? nil : disk.model
    }

    /// Everything that names the disk, for a tooltip.
    static func help(_ disk: DiskSample) -> String {
        [title(disk), device(disk), disk.imagePath].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Network

struct NetworkDetail: View {
    @Environment(AppModel.self) private var model
    /// Bumped by the shortcut beside the title, for the Internet quality card.
    @State private var revealTest = 0
    var link: NetworkInterfaceSample
    var snapshot: SystemSnapshot

    var body: some View {
        let received = model.networkInHistory[link.id]?.values ?? []
        let sent = model.networkOutHistory[link.id]?.values ?? []
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                SpeedTestHeader(title: link.displayName, subtitle: link.name, action: "Test Internet quality…",
                                help: "Go to the Internet quality test below. It starts only when you click Run Test, "
                                    + "as it loads the connection for about \(Int(NetworkQuality.typicalSeconds)) s.",
                                last: lastTest()) {
                    SpeedTestHeader.scrollToCard(proxy)
                    revealTest += 1
                }
                MetricStrip(tint: Theme.network) {
                    Stat(label: "Receive", number: link.receivedBytesPerSecond, color: Theme.network, format: Format.bitsPerSecond)
                    Stat(label: "Send", number: link.sentBytesPerSecond, color: Theme.networkSecondary, format: Format.bitsPerSecond)
                    Stat(label: "Received", value: Format.bytes(link.totalReceived))
                    Stat(label: "Sent", value: Format.bytes(link.totalSent))
                }
                // A card like Apps using the network below it, so the two
                // plots run edge to edge over the same minutes.
                ChartCard(title: "Throughput", trailing: "receive solid, send dashed", tint: Theme.network) {
                    GraphView(series: [
                                  GraphSeries(values: received, color: Theme.network),
                                  GraphSeries(values: sent, color: Theme.networkSecondary, fill: false, dashed: true),
                              ],
                              glows: true, minimumCeiling: 125_000, axis: Format.bitsPerSecond, axisUnits: .bits, cornerRadius: 8)
                        .chartFrame(height: DetailGraph.primary, tint: Theme.network)
                }
                NetworkAppsSection()
                InternetQualityCard(interface: link.name, name: link.displayName, reveal: revealTest)
                    .equatable()
                    .id(SpeedTestHeader.card)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    FactRow(label: "Connection", value: link.kind.rawValue.capitalized)
                    if let speed = link.linkSpeed { FactRow(label: "Link speed", value: Format.bitsPerSecond(Double(speed) / 8)) }
                    ForEach(link.addresses, id: \.self) { address in
                        FactRow(label: address.contains(":") ? "IPv6" : "IPv4", value: address)
                    }
                }
            }
        }
    }

    /// This link's last Internet quality result, or that a test is running on it.
    private func lastTest() -> String? {
        let store = NetworkQualityStore.shared
        if store.running?.interface == link.name { return "Testing now…" }
        guard let result = store.results(for: link.name).first else { return nil }
        let rates = [("↓", result.downloadBitsPerSecond), ("↑", result.uploadBitsPerSecond)].compactMap { arrow, bits in
            bits.map { "\(arrow) \(Format.bitsPerSecond($0 / 8))" }
        }
        return "Last: \(rates.joined(separator: " ")) · \(Format.ago(-result.date.timeIntervalSinceNow))"
    }
}

// MARK: - Speed test shortcut

/// A detail's title with a way to its speed test beside it: a button that
/// scrolls to the test's card and hands Run Test the focus, without starting
/// anything (a test loads the connection or the disk), and the last result.
/// When one line can't hold them, the shortcut moves under the title.
private struct SpeedTestHeader: View {
    /// The speed test card's scroll anchor.
    static let card = "speedTestCard"

    var title: String
    var subtitle: String
    /// "Test disk speed…".
    var action: String
    var help: String
    /// "Last: ↓ 303 Mbps ↑ 365 Mbps · 2 h ago", or that a test is running.
    var last: String?
    var reveal: () -> Void

    /// Brings the speed test's card to the top of the page.
    static func scrollToCard(_ proxy: ScrollViewProxy) {
        // A one-off scroll the user asked for, not a value that changes per tick.
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(card, anchor: .top)
        }
    }

    var body: some View {
        TitleShortcutRow {
            // In a narrow pane the subtitle gives way to the title, unless
            // that's a disk image's long name, which is cut in the middle
            // (whole in the tooltip) so its "disk4 · Disk image" still shows.
            Text(title).font(.largeTitle.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(title)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: reveal) {
                    Label(action, systemImage: "speedometer")
                }
                .controlSize(.small)
                .help(help)
                if let last {
                    Text(last)
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(last)
                }
            }
            Text(subtitle).font(.title3).foregroundStyle(.secondaryText).lineLimit(1).help(subtitle)
        }
    }
}

/// A title, a shortcut and a subtitle on one line, level on their first
/// baselines, with the subtitle at the far end. When they don't fit, the
/// title and subtitle keep the first line and the shortcut takes one under
/// them. A `Layout`, not `ViewThatFits`, so the page's tick doesn't measure
/// every arrangement again.
private struct TitleShortcutRow: Layout {
    private let spacing: CGFloat = 16
    private let lineGap: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// The title's, shortcut's and subtitle's frames for a width, and the size they take.
    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> (frames: [CGRect], size: CGSize) {
        guard subviews.count == 3 else { return ([], .zero) }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let oneLine = sizes.reduce(0) { $0 + $1.width } + 2 * spacing
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? oneLine
        let stacked = oneLine > width
        var widths = sizes.map(\.width)
        if stacked {
            // A title too long for the line (a disk image's) leaves the
            // subtitle up to 40% of it; a shorter one keeps its width.
            let subtitleShare = min(sizes[2].width, width * 0.4)
            widths[0] = min(sizes[0].width, max(width - subtitleShare - spacing, 0))
            widths[1] = min(sizes[1].width, width)
            widths[2] = max(min(sizes[2].width, width - widths[0] - spacing), 0)
        }
        let baselines = subviews.indices.map { index in
            subviews[index].dimensions(in: ProposedViewSize(width: widths[index], height: sizes[index].height))[VerticalAlignment.firstTextBaseline]
        }
        let firstLine = stacked ? [0, 2] : [0, 1, 2]
        let baseline = firstLine.map { baselines[$0] }.max() ?? 0
        var frames = sizes.indices.map { index in
            CGRect(x: 0, y: baseline - baselines[index], width: widths[index], height: sizes[index].height)
        }
        frames[2].origin.x = width - widths[2]
        if stacked {
            frames[1].origin.y = (firstLine.map { frames[$0].maxY }.max() ?? 0) + lineGap
        } else {
            frames[1].origin.x = widths[0] + spacing
        }
        return (frames, CGSize(width: width, height: frames.map(\.maxY).max() ?? 0))
    }
}
