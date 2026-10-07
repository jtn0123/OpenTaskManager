import Observation
import OTMKit
import SwiftUI

/// The chip layout, read once per session the first time the CPU detail
/// shows. Nothing in it changes while the Mac runs. Most of it takes a
/// millisecond or two to read, so it's there for the detail's first frame
/// and nothing below the card jumps; the memory type, which waits for
/// system_profiler, follows off the main actor.
@Observable
@MainActor
final class ChipLayoutStore {
    static let shared = ChipLayoutStore()

    /// "LPDDR5", once system_profiler has said.
    private(set) var memoryType: String?
    @ObservationIgnored private var read: ChipLayout?
    @ObservationIgnored private var askedForMemoryType = false

    func layout(topology: CPUTopology) -> ChipLayout {
        var layout = read ?? ChipLayoutReader.read(topology: topology, memoryType: false)
        read = layout
        layout.memoryType = memoryType
        return layout
    }

    func loadMemoryType() async {
        guard !askedForMemoryType else { return }
        askedForMemoryType = true
        memoryType = await Task.detached(priority: .utility) { ChipLayoutReader.memoryType() }.value
    }
}

/// What each part of the chip is doing now, from the sample the page
/// already has: nothing here is collected for the card.
struct ChipActivity: Equatable {
    /// Average load of each kind of core, by level.
    var load: [Int: Double]
    /// Each cluster's clock and residency, from the sampler's IOReport read
    /// (the clock graph's and the Thermals table's).
    var clusters: [ClusterPower]
    /// Each GPU's utilization, in the sampler's order; nil where it isn't reported.
    var gpuUtilization: [Double?]
    var gpuIDs: [String]
    /// nil when the Neural Engine's power isn't measured.
    var neuralEngineWatts: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// Whether the Performance page lists Power, for the Neural Engine's link.
    var hasPowerDetail: Bool
}

/// "Chip layout" on the CPU detail: the chip's parts as macOS describes
/// them, each with what it's doing now under a rule. A kind of core shows
/// its CPUs grouped by cluster as the device tree groups them (never
/// guessed from the numbering), its caches, and its load and its clusters'
/// clocks; the GPU, Neural Engine and memory link to their own details.
struct ChipLayoutCard: View, Equatable {
    let layout: ChipLayout
    let activity: ChipActivity
    /// Shows the CPU graph by core type (or each core, with one kind) and scrolls to it.
    var showGraphs: () -> Void
    var select: (Resource) -> Void

    /// The links' actions don't change what's drawn.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout == rhs.layout && lhs.activity == rhs.activity
    }

    var body: some View {
        Card(tint: Theme.cpu) {
            header
            FillGrid(minimum: 270, spacing: 10) {
                ForEach(layout.coreTypes) { type in
                    CoreTypeTile(type: type, clusters: layout.clusters(of: type.level), cpus: layout.cpus(of: type.level),
                                 single: layout.coreTypes.count == 1, l3Bytes: layout.coreTypes.count == 1 ? layout.l3Bytes : nil) {
                        CoreTypeActivity(load: activity.load[type.level], name: type.name,
                                         clusters: activity.clusters.filter { $0.tierLevel == type.level },
                                         single: layout.coreTypes.count == 1, showGraphs: showGraphs)
                    }
                }
            }
            FillGrid(minimum: 170, spacing: 10) {
                ForEach(layout.gpus.indices, id: \.self) { index in gpuTile(index) }
                if let engine = layout.neuralEngine { neuralEngineTile(engine) }
                memoryTile
            }
            Text(ChipLayoutReader.sources)
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Label("Chip layout", systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(Theme.cpu)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text([layout.chip, layout.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondaryText)
        }
    }

    /// "arm64 · 18 cores: 6 Super, 12 Performance", with logical CPUs where they differ.
    private var summary: String {
        let physical = layout.coreTypes.reduce(0) { $0 + $1.physicalCores }
        let logical = layout.coreTypes.reduce(0) { $0 + $1.logicalCores }
        return "\(layout.architecture) · \(layout.coreSummary)" + (logical != physical ? " · \(logical) logical CPUs" : "")
    }

    private func gpuTile(_ index: Int) -> some View {
        let gpu = layout.gpus[index]
        let utilization = activity.gpuUtilization.indices.contains(index) ? activity.gpuUtilization[index] : nil
        let id = activity.gpuIDs.indices.contains(index) ? activity.gpuIDs[index] : nil
        return ChipTile(title: layout.gpus.count > 1 ? "GPU \(index + 1)" : "GPU", color: Theme.gpu,
                        link: id.map { id in ("GPU details", { select(.gpu(id)) }) }) {
            Text(gpu.cores.map { "\($0) cores" } ?? "Core count not reported").font(.callout)
            // A virtual machine's GPU has no model name, only "GPU".
            if gpu.name != "GPU" {
                Text(gpu.name).font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
            }
        } now: {
            NowLine(text: utilization.map { "\(Format.percent($0)) busy" } ?? Unavailable.gpuUtilization)
        }
    }

    private func neuralEngineTile(_ engine: ChipLayout.Engine) -> some View {
        ChipTile(title: "Neural Engine", color: Theme.neuralEngine,
                 link: activity.hasPowerDetail ? ("Power", { select(.power) }) : nil) {
            Text(engine.cores.map { "\($0) cores" } ?? "Core count not reported").font(.callout)
            Text("Present in the I/O Registry").font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
        } now: {
            NowLine(text: activity.neuralEngineWatts.map { "\(Format.watts($0)) power" } ?? "Power not reported")
                .help("macOS reports the Neural Engine's power, not how busy it is.")
        }
    }

    private var memoryTile: some View {
        ChipTile(title: "Memory", color: Theme.memory, link: ("Memory details", { select(.memory) })) {
            Text(Format.wholeBytes(layout.memoryBytes)).font(.callout)
            Text(layout.memoryType ?? "Type not reported").font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
        } now: {
            let fraction = activity.memoryTotal > 0 ? Double(activity.memoryUsed) / Double(activity.memoryTotal) : 0
            NowLine(text: "\(Format.bytes(activity.memoryUsed)) used (\(Format.percent(fraction)))")
        }
    }
}

/// One part of the chip: its title and a link to its details, what it is
/// above a rule, and what it's doing now below it.
private struct ChipTile<Static: View, Now: View>: View {
    var title: String
    var color: Color
    var link: (title: String, action: () -> Void)?
    @ViewBuilder var content: Static
    @ViewBuilder var now: Now

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let link {
                    Button(link.title, action: link.action)
                        .buttonStyle(.link)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            content
            Spacer(minLength: 0)
            Divider()
            now
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.fillShade.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.22)))
    }
}

/// A measured reading under a tile's rule, marked as live.
private struct NowLine: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            NowMark()
            Text(text).font(.callout).monospacedDigit().lineLimit(1)
        }
    }
}

/// "Now": what follows is measured, not a property of the chip.
private struct NowMark: View {
    var body: some View {
        Text("Now")
            .font(.metadata.weight(.semibold))
            .foregroundStyle(.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.secondaryText.opacity(0.5)))
            .fixedSize()
    }
}

/// A kind of core: how many, its CPUs by cluster, its caches; then its
/// load and clocks now, from `activity`.
private struct CoreTypeTile<Activity: View>: View {
    let type: ChipLayout.CoreType
    let clusters: [ChipLayout.Cluster]
    /// Every CPU of the type, when the device tree accounts for all of them.
    let cpus: [Int]?
    let single: Bool
    let l3Bytes: Int?
    @ViewBuilder var activity: Activity

    var body: some View {
        let color = Theme.tier(type.level)
        ChipTile(title: "\(type.name) cores", color: color, link: nil) {
            Text(counts).font(.callout)
            if cpus != nil {
                ClusterDiagram(clusters: clusters, color: color)
            } else {
                Text("macOS doesn't say which CPUs are in which cluster.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
            }
            caches
        } now: {
            activity
        }
    }

    /// "6 cores · 1 cluster", with logical CPUs where they differ.
    private var counts: String {
        var parts = ["\(type.physicalCores) cores"]
        if type.logicalCores != type.physicalCores { parts.append("\(type.logicalCores) logical CPUs") }
        if cpus != nil { parts.append(clusters.count == 1 ? "1 cluster" : "\(clusters.count) clusters") }
        return parts.joined(separator: " · ")
    }

    private var caches: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            if type.l1InstructionBytes != nil || type.l1DataBytes != nil {
                GridRow {
                    Text("L1").foregroundStyle(.secondaryText)
                    Text(l1)
                }
            }
            if let l2 = type.l2Bytes {
                GridRow {
                    Text("L2").foregroundStyle(.secondaryText)
                    Text(Self.l2(l2, count: type.l2Count, sharedBy: type.coresPerL2))
                }
            }
            if let l3Bytes {
                GridRow {
                    Text("L3").foregroundStyle(.secondaryText)
                    Text(Format.wholeBytes(UInt64(l3Bytes)))
                }
            }
        }
        .font(.callout)
    }

    /// "192 KB instruction + 128 KB data, per core".
    private var l1: String {
        let parts = [type.l1InstructionBytes.map { "\(Format.wholeBytes(UInt64($0))) instruction" },
                     type.l1DataBytes.map { "\(Format.wholeBytes(UInt64($0))) data" }].compactMap { $0 }
        return parts.joined(separator: " + ") + ", per core"
    }

    /// "16 MB, shared by 6 cores", "2 × 8 MB, each shared by 6 cores".
    static func l2(_ bytes: Int, count: Int?, sharedBy cores: Int?) -> String {
        let size = Format.wholeBytes(UInt64(bytes))
        guard let cores, cores > 1 else { return size }
        if let count, count > 1 { return "\(count) × \(size), each shared by \(cores) cores" }
        return "\(size), shared by \(cores) cores"
    }
}

/// The CPUs of a kind of core in their clusters: a box per cluster, a cell
/// per CPU with the number the CPU graphs use.
private struct ClusterDiagram: View {
    let clusters: [ChipLayout.Cluster]
    let color: Color

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 6) {
            ForEach(clusters) { cluster in
                HStack(spacing: 3) {
                    ForEach(cluster.cpus, id: \.self) { cpu in
                        Text("\(cpu)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .frame(minWidth: 22, minHeight: 18)
                            .background(color.fillShade.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.35)))
                    }
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .help("A cluster in the device tree (logical cluster \(cluster.id)): CPUs \(ChipLayout.cpuRanges(cluster.cpus))")
            }
        }
    }
}

/// A kind of core's load now, and each of its clusters' clock and share of
/// time running, with a link to its graphs.
private struct CoreTypeActivity: View {
    let load: Double?
    let name: String
    let clusters: [ClusterPower]
    let single: Bool
    var showGraphs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                NowMark()
                Text(load.map { "\(Format.percent($0)) load" } ?? "Load —").font(.callout).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                Button(single ? "Every core's graph" : "Graph by core type", action: showGraphs)
                    .buttonStyle(.link)
                    .font(.callout)
                    .lineLimit(1)
                    .help(single ? "Show each core's load on the CPU graph" : "Show the CPU graph for each kind of core")
            }
            if clusters.isEmpty {
                Text("Clock speed not reported").font(.callout).foregroundStyle(.secondaryText)
            }
            ForEach(clusters) { cluster in
                Text(clock(cluster))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .help("IOReport's \(cluster.channel) channel, which the clock graph and the Thermals table read too. "
                        + "macOS doesn't say which of the \(name) clusters above it is.")
            }
        }
    }

    /// "Performance 0: 3.21 GHz, running 18%", or idle.
    private func clock(_ cluster: ClusterPower) -> String {
        let speed = cluster.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "idle"
        let running = cluster.activeFraction.map { ", running \(Format.percent($0))" } ?? ""
        return "\(cluster.name): \(speed)\(running)"
    }
}
