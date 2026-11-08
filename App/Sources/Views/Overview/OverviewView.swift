import OTMKit
import SwiftUI

/// At-a-glance dashboard: a live graph per resource, a small graph of every
/// core, throughput, and which apps are using what.
///
/// The cards keep one order at every width (CPU, Memory, GPU and Power, the
/// cores, Disk and Network, the top apps, Storage), so resizing never moves
/// what's where; only how many share a row changes. Every live graph on the
/// page covers one window, 2 minutes, fitted in steps to what's been
/// collected until then (`GraphCoverage.shortFittedCapacity`), so readings
/// fill most of each graph from the first seconds and the rest is drawn as
/// not yet collected. In a narrow window (820 points, with or without the
/// sidebar) the graphs are a little shorter. The cores fold to a line on a
/// click at any width, and stay as they were left when the window is resized.
struct OverviewView: View {
    /// Below this width of the page, the narrow layout.
    private static let narrowWidth: CGFloat = 900

    @Environment(AppModel.self) private var model
    @State private var isNarrow = false

    var body: some View {
        let narrowWidth = Self.narrowWidth
        Group {
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        resources(snapshot)
                        // A GPU that doesn't say how busy it is (a virtual
                        // machine's) would only get an empty graph, so it
                        // takes a line and the cards below move up.
                        if let gpu = snapshot.gpus.first, gpu.deviceUtilization == nil { gpuStrip(gpu) }
                        CoreGraphsCard()
                        throughput(snapshot)
                        topApps
                        StorageCard(volumes: snapshot.volumes)
                    }
                    .padding(20)
                    // Every graph on the page covers this one window. It changes a
                    // handful of times as the first 2 minutes fill, not per tick.
                    .environment(\.graphWindow,
                                 GraphCoverage.shortFittedCapacity(samples: model.cpuHistory.count, span: AppModel.shortGraphSpan))
                }
                .defaultScrollAnchor(Self.startsAtEnd ? .bottom : .top)
                .followsEnd(Self.startsAtEnd)
                // Keeps nettop running whether Top Network is a card or a strip,
                // so switching between them doesn't drop a reading.
                .task { await model.networkActivity.track(model: model) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Only crossing the breakpoint changes anything, not every resize.
        // Read while the first sample is taken, so the cards start in their
        // layout rather than swapping over (which lost -openScroll bottom).
        .onGeometryChange(for: Bool.self) { $0.size.width < narrowWidth } action: { isNarrow = $0 }
    }

    /// `-openScroll bottom` starts the page scrolled to the end, for screenshots.
    private static let startsAtEnd = LaunchArgument.string("openScroll") == "bottom"

    // MARK: Sections

    /// CPU, Memory, and the GPU and power where this Mac reports them: two to
    /// a row at 820 points and up, each mostly its graph.
    private func resources(_ snapshot: SystemSnapshot) -> some View {
        let height: CGFloat = isNarrow ? 130 : 150
        let power = snapshot.power
        return FillGrid(minimum: 360) {
            CPUGraphCard(chartHeight: height)
            MemoryGraphCard(chartHeight: height)
            if let gpu = snapshot.gpus.first, let busy = gpu.deviceUtilization { GPUGraphCard(gpu: gpu, busy: busy, chartHeight: height) }
            if power.systemWatts != nil || power.components != nil { PowerGraphCard(power: power, chartHeight: height) }
        }
    }

    /// Disk and Network, side by side, their graphs as wide as their cards.
    private func throughput(_ snapshot: SystemSnapshot) -> some View {
        let height: CGFloat = isNarrow ? 100 : 110
        return FillGrid(minimum: 360) {
            diskCard(snapshot, chartHeight: height)
            NetworkTrafficCard(chartHeight: height)
        }
    }

    /// Which apps use the most CPU, memory, energy and network.
    @ViewBuilder private var topApps: some View {
        let groups = model.appGroups
        // Unknown until the first samples say; until then the card stays.
        let measuresEnergy = model.measuresProcessEnergy != false
        let networkRanks = TopNetworkCard.hasRanking(model.networkActivity)
        FillGrid(minimum: isNarrow ? 260 : 280) {
            TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: groups,
                        metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) }, column: .cpu)
            TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: groups,
                        metric: { Double($0.memory) }, format: { Format.bytes($0.memory) }, column: .memory)
            if measuresEnergy {
                TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: groups,
                            metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, column: .power,
                            minimum: 0.01, cutoff: "10 mW")
            }
            if networkRanks { TopNetworkCard() }
        }
        // A whole card would only say there's nothing to rank, so
        // each takes a line and the cards above share its width. Two share
        // a row only where neither explanation is cut short.
        if !measuresEnergy || !networkRanks {
            FillGrid(minimum: 420, spacing: 12) {
                if !measuresEnergy {
                    NoticeStrip(title: "Top Energy", symbol: "bolt.fill", color: Theme.power, text: Unavailable.energy)
                }
                if !networkRanks { TopNetworkStrip() }
            }
        }
    }

    /// The GPU's name and memory in use on one line, for a GPU that doesn't
    /// report utilization. Performance › GPU keeps its memory graph and GPU
    /// time by app.
    private func gpuStrip(_ gpu: GPUSample) -> some View {
        // A paravirtual GPU's name is just "GPU", which the title already says.
        let name = gpu.tellingName
        let memory = gpu.memoryInUse.map { (label: "Memory in use", value: Format.bytes($0)) }
        return NoticeStrip(title: "GPU", symbol: "cpu.fill", color: Theme.gpu,
                           text: [name, Unavailable.gpuUtilization].compactMap { $0 }.joined(separator: " · "),
                           help: Unavailable.gpuUtilizationDetail + " Performance › GPU shows its memory in use and GPU time by app.",
                           trailing: memory)
    }

    private func diskCard(_ snapshot: SystemSnapshot, chartHeight: CGFloat) -> some View {
        let ids = snapshot.disks.map(\.id)
        return ThroughputCard(
            title: "Disk", symbol: "internaldrive", color: Theme.disk, secondaryColor: Theme.diskSecondary,
            labels: ("Read", "Write"),
            rates: (snapshot.disks.reduce(0) { $0 + $1.readBytesPerSecond }, snapshot.disks.reduce(0) { $0 + $1.writeBytesPerSecond }),
            histories: (GraphMath.tailSum(ids.map { model.diskReadHistory[$0]?.values ?? [] }),
                        GraphMath.tailSum(ids.map { model.diskWriteHistory[$0]?.values ?? [] })),
            format: Format.bytesPerSecond, minimumScale: 1_048_576, units: .binaryBytes, chartHeight: chartHeight
        )
    }
}

// MARK: - Pieces

/// A one-line note where a card or graph would be, so saying there's
/// nothing to show doesn't take its room: a reading this Mac can't make,
/// or a ranking with nothing in it right now. A dashed edge marks something
/// missing rather than a reading; a quiet ranking keeps a plain one.
struct NoticeStrip: View {
    var title: String
    var symbol: String
    var color: Color
    var text: String
    /// The hover text; by default, that the reading isn't available.
    var help: String?
    var isMissing = true
    /// Metadata-sized, for a row among an inspector's graphs.
    var compact = false
    /// A reading that is measured, at the end of the line: "Memory in use 301 MB".
    var trailing: (label: String, value: String)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10)
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).fontWeight(.medium).fixedSize()
            Text(text).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing.label).foregroundStyle(.secondaryText).lineLimit(1).fixedSize()
                Text(trailing.value).fontWeight(.medium).monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        .font(compact ? .metadata : .callout)
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 6 : 8)
        .background(color.fillShade.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: isMissing ? [4, 3] : [])))
        .help(help ?? "\(title) isn't available. \(text)")
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// For `-openScroll bottom`: the cards fill in and swap over the first
    /// samples, which left the page partway down, so it follows the end as
    /// the page grows until someone scrolls. Without the flag, nothing is attached.
    @ViewBuilder func followsEnd(_ follows: Bool) -> some View {
        if #available(macOS 15, *), follows {
            modifier(FollowsEnd())
        } else {
            self
        }
    }
}

@available(macOS 15, *)
private struct FollowsEnd: ViewModifier {
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, _ in
                if isFollowing { position.scrollTo(edge: .bottom) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isFollowing = false }
            }
    }
}

/// Top Network as a strip while there's nothing to rank: still measuring,
/// nettop unavailable, or no app moving data lately. The card comes back
/// as soon as an app sends or receives anything, and keeps its rows through
/// a pause (`TopNetworkCard.holdReadings`), so it never shows empty.
private struct TopNetworkStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.networkActivity
        let cadence = "Read with nettop every \(Format.timeSpan(NetworkActivityStore.refreshSeconds)) while this page is open."
        if store.isUnavailable {
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: Unavailable.processNetwork)
        } else if !store.hasMeasured {
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: "Measuring which apps use the network…",
                        help: cadence, isMissing: false)
        } else {
            let hold = TopNetworkCard.holdReadings
            let span = Format.roughDuration(Double(min(store.apps.length, hold)) * NetworkActivityStore.refreshSeconds)
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: "Nothing sent or received in the last \(span)",
                        help: "\(cadence) The ranking comes back when an app sends or receives something.", isMissing: false)
        }
    }
}

/// Receive and send rates across the primary network interfaces, with their
/// history. Reads the model itself, so on pages that otherwise refresh
/// slowly (Connections) only this card redraws every tick.
struct NetworkTrafficCard: View {
    @Environment(AppModel.self) private var model
    var title = "Network"
    var compact = false
    var chartHeight: CGFloat = 110

    var body: some View {
        let links = model.snapshot?.network.filter(\.isPrimary) ?? []
        let ids = links.map(\.id)
        ThroughputCard(
            title: title, symbol: "network", color: Theme.network, secondaryColor: Theme.networkSecondary,
            labels: ("Receive", "Send"),
            rates: (links.reduce(0) { $0 + $1.receivedBytesPerSecond }, links.reduce(0) { $0 + $1.sentBytesPerSecond }),
            histories: (GraphMath.tailSum(ids.map { model.networkInHistory[$0]?.values ?? [] }),
                        GraphMath.tailSum(ids.map { model.networkOutHistory[$0]?.values ?? [] })),
            format: Format.bitsPerSecond, minimumScale: 125_000, units: .bits, compact: compact, chartHeight: chartHeight
        )
    }
}

struct ThroughputCard: View {
    private static let compactFont = NSFont.numeric(size: 13, weight: .medium)

    var title: String
    var symbol: String
    var color: Color
    var secondaryColor: Color
    var labels: (String, String)
    var rates: (Double, Double)
    var histories: ([Double], [Double])
    var format: (Double) -> String
    /// Keeps a quiet link from magnifying noise to full height.
    var minimumScale: Double
    var units: GraphMath.AxisUnits
    /// One short row with the rates beside the graph, to sit among summary
    /// cards (Connections'), over a fixed 2 minutes. The graph grows to
    /// whatever height the row gives the card.
    var compact = false
    /// The least the full card's graph is drawn at.
    var chartHeight: CGFloat = 110
    /// What the compact card's graph column has room for. Set from its
    /// width, so it changes on a resize, never with the numbers.
    @State private var graphRoom = GraphRoom.graphAndAxis

    /// A graph column narrower than a readable graph shows none, and its
    /// time axis shows only where its words fit on one line: squeezed, they
    /// wrapped a letter at a time, made the card (and the cards in its row)
    /// tall, and pushed it past the page's edge.
    private enum GraphRoom {
        case none, graph, graphAndAxis

        init(width: CGFloat) {
            switch width {
            case 96...: self = .graphAndAxis
            case 40...: self = .graph
            default: self = .none
            }
        }
    }

    var body: some View {
        if compact {
            Card(tint: color) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(title, systemImage: symbol)
                            .font(.explanation.weight(.medium))
                            .foregroundStyle(.secondaryText)
                        rate(rates.0, symbol: "arrow.down", color: color).help(labels.0)
                        rate(rates.1, symbol: "arrow.up", color: secondaryColor).help(labels.1)
                    }
                    // Fixed, so the graph doesn't shift as the numbers change width.
                    .frame(width: 112, alignment: .leading)
                    VStack(spacing: 2) {
                        if graphRoom == .none {
                            Color.clear
                        } else {
                            graph(axis: nil, capacity: AppModel.shortGraphSpan, showsGrid: false)
                                .frame(minHeight: 34, maxHeight: .infinity)
                        }
                        if graphRoom == .graphAndAxis { TimeAxis(samples: AppModel.shortGraphSpan) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .onGeometryChange(for: GraphRoom.self) { GraphRoom(width: $0.size.width) } action: { graphRoom = $0 }
                }
            }
        } else {
            // The rates as figures in the graph's key, the received or read
            // line solid and the other dashed, as they're drawn.
            OverviewGraphCard(
                title: title, symbol: symbol, tint: color,
                keys: [
                    ChartKey(name: labels.0, color: color, figure: .init(value: rates.0, format: format)),
                    ChartKey(name: labels.1, color: secondaryColor, mark: .dashed, figure: .init(value: rates.1, format: format)),
                ],
                chartHeight: chartHeight
            ) {
                graph(axis: format, capacity: nil, showsGrid: true)
            }
        }
    }

    /// `capacity` nil takes the page's window, `graphWindow`.
    private func graph(axis: ((Double) -> String)?, capacity: Int?, showsGrid: Bool) -> GraphView {
        GraphView(
            series: [
                GraphSeries(values: histories.0, color: color),
                GraphSeries(values: histories.1, color: secondaryColor, fill: false, dashed: true),
            ],
            capacity: capacity, showsGrid: showsGrid, glows: true, minimumCeiling: minimumScale, axis: axis, axisUnits: units,
            cornerRadius: compact ? 0 : 8
        )
    }

    private func rate(_ value: Double, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            AnimatedNumber(value: value, format: format, font: Self.compactFont)
        }
    }
}

/// Space on each mounted volume.
private struct StorageCard: View {
    var volumes: [VolumeInfo]

    var body: some View {
        Card(tint: .indigo) {
            Label("Storage", systemImage: "externaldrive").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(volumes.prefix(4)) { volume in
                    let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(volume.availableBytes)) free")
                                .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                        }
                        StackedBar(segments: [.init(label: "Used", value: used, color: Theme.pressure(used))], total: 1, height: 8)
                        Text("\(Format.bytes(volume.usedBytes)) of \(Format.bytes(volume.totalBytes)) used")
                            .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                    }
                }
            }
        }
    }
}
