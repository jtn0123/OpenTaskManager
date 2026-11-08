import OTMKit
import SwiftUI

/// A small graph of every logical CPU's load, grouped by core type, on one
/// shared scale (the CPU graphs' `CPUGraphScale`), so a busy core stands out
/// at a glance. A click on the heading folds it to each core type's load;
/// open or folded, it stays as it was left at every width.
struct CoreGraphsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.graphWindow) private var window
    @AppStorage("overviewShowsCores") private var isOpen = true
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto
    /// The tiles' shared auto bound, held between samples.
    @State private var bounds = AutoScaleBounds()

    var body: some View {
        let topology = model.topology
        let usage = model.snapshot?.cpu.coreUsage ?? []
        let groups = topology.tiers.map { tier in
            CoreGroup(tier: tier, cpus: topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level })
        }.filter { !$0.cpus.isEmpty }
        let histories = isOpen ? model.coreHistory : []
        // Every tile shares one scale, so the cores compare at a glance.
        let top = scale == .auto && isOpen
            ? bounds.bound("cores", peak: histories.map { AutoScaleBounds.peak($0.values, capacity: window) }.max() ?? 0)
            : 1
        Card {
            Button {
                isOpen.toggle()
            } label: {
                heading(topology, groups: groups, usage: usage, top: top).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the graph of each core" : "Show a graph of each core's load")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    CoreGridLayout(counts: groups.map(\.cpus.count), tileHeight: Self.tileHeight) {
                        ForEach(groups, id: \.tier.level) { group in
                            groupHeading(group, usage: usage)
                            ForEach(group.cpus, id: \.self) { cpu in
                                CoreGraphTile(cpu: cpu, values: histories.indices.contains(cpu) ? histories[cpu].values : [],
                                              usage: usage.indices.contains(cpu) ? usage[cpu] : 0, top: top,
                                              color: Theme.tier(group.tier.level))
                            }
                        }
                    }
                    TimeAxis()
                        .padding(.top, 5)
                }
            }
        }
    }

    /// A 17-point line for the labels over a 48-point graph.
    private static let tileHeight: CGFloat = 66

    private struct CoreGroup {
        var tier: CPUTopology.Tier
        var cpus: [Int]

        func average(_ usage: [Double]) -> Double {
            let loads = cpus.map { usage.indices.contains($0) ? usage[$0] : 0 }
            return loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
        }
    }

    /// "Cores", the chip and the scale; folded, each core type's load instead.
    private func heading(_ topology: CPUTopology, groups: [CoreGroup], usage: [Double], top: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondaryText)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .accessibilityHidden(true)
            Text("Cores").font(.headline)
            Spacer(minLength: 8)
            if isOpen {
                // The tiles have no axis, so the heading gives their shared scale.
                let note = " · 0–\(CPUGraphScale.axisLabel(top)) scale" + (scale == .auto ? ", auto" : "")
                Text("\(topology.brand) · \(topology.logicalCores) cores" + note)
                    .font(.explanation).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
            } else {
                HStack(spacing: 12) {
                    ForEach(groups, id: \.tier.level) { group in
                        HStack(spacing: 5) {
                            Circle().fill(Theme.tier(group.tier.level)).frame(width: 8, height: 8)
                            Text("\(group.tier.name) \(Format.percent(group.average(usage)))")
                        }
                    }
                }
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    /// A core type's name over its tiles, with how many and their average load.
    private func groupHeading(_ group: CoreGroup, usage: [Double]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Theme.tier(group.tier.level)).frame(width: 8, height: 8)
            Text("\(group.tier.name) cores").font(.callout.weight(.medium))
            Text("\(group.cpus.count) · \(Format.percent(group.average(usage))) average")
                .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
        }
        .lineLimit(1)
    }
}

/// Lays out core-type headings and core tiles as `CoreGrid` (OTMKit) says.
/// Its subviews are, for each core type in turn, its heading, then a tile
/// per core. The grid is worked out from the width it's offered, during
/// layout, so the tiles never start one per row while a width is measured.
private struct CoreGridLayout: Layout {
    static let minimumTile: CGFloat = 96
    static let spacing: CGFloat = 6
    static let groupSpacing: CGFloat = 18
    /// Under a heading, before its tiles.
    static let headingGap: CGFloat = 6
    /// Between one core type's last row and the next one's heading.
    static let groupGap: CGFloat = 12

    var counts: [Int]
    var tileHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(counts.reduce(0, +)) * (Self.minimumTile + Self.spacing)
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(width: bounds.width, subviews: subviews)
        for (index, frame) in placed.frames.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each subview's frame, in order, and the height they take.
    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let grid = CoreGrid(counts: counts, width: Double(width), minimum: Double(Self.minimumTile), spacing: Double(Self.spacing),
                            groupSpacing: Double(Self.groupSpacing))
        let tile = CGFloat(grid.tileWidth)
        var frames: [CGRect] = []
        var index = 0
        if grid.sharesRow {
            // Side by side: each heading over its own tiles, the tiles on one line.
            let headingHeight = headingHeights(subviews: subviews, widths: counts.map { groupWidth($0, tile: tile) }).max() ?? 0
            var x: CGFloat = 0
            for count in counts where index < subviews.count {
                let groupWidth = groupWidth(count, tile: tile)
                frames.append(CGRect(x: x, y: 0, width: groupWidth, height: headingHeight))
                for column in 0..<count {
                    frames.append(CGRect(x: x + CGFloat(column) * (tile + Self.spacing), y: headingHeight + Self.headingGap,
                                         width: tile, height: tileHeight))
                }
                index += count + 1
                x += groupWidth + Self.groupSpacing
            }
            return (frames, counts.isEmpty ? 0 : headingHeight + Self.headingGap + tileHeight)
        }
        var y: CGFloat = 0
        for count in counts where index < subviews.count {
            if index > 0 { y += Self.groupGap }
            let headingHeight = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            frames.append(CGRect(x: 0, y: y, width: width, height: headingHeight))
            y += headingHeight + Self.headingGap
            for row in grid.rows(count: count) {
                for column in 0..<row.count {
                    frames.append(CGRect(x: CGFloat(column) * (tile + Self.spacing), y: y, width: tile, height: tileHeight))
                }
                y += tileHeight + Self.spacing
            }
            y -= Self.spacing
            index += count + 1
        }
        return (frames, max(y, 0))
    }

    private func groupWidth(_ count: Int, tile: CGFloat) -> CGFloat {
        CGFloat(count) * tile + CGFloat(max(count - 1, 0)) * Self.spacing
    }

    /// Each heading's height at its group's width, side by side.
    private func headingHeights(subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        var index = 0
        var heights: [CGFloat] = []
        for (count, width) in zip(counts, widths) where index < subviews.count {
            heights.append(subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
            index += count + 1
        }
        return heights
    }
}

/// One logical CPU's recent load as a small graph, under its number and its
/// reading now, drawn in `CoreTileLook` as Performance's Every core tiles are. The labels
/// have a line of their own, so a busy core's trace never runs under them.
private struct CoreGraphTile: View {
    var cpu: Int
    var values: [Double]
    var usage: Double
    /// The top of the scale every tile shares.
    var top: Double
    var color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CoreTileLook.cornerRadius)
        VStack(spacing: 0) {
            HStack {
                Text("\(cpu)").foregroundStyle(.secondaryText)
                Spacer(minLength: 4)
                Text(Format.percent(usage)).foregroundStyle(CoreTileLook.isHot(usage) ? AnyShapeStyle(color) : AnyShapeStyle(.secondaryText))
            }
            .font(CoreTileLook.labelFont)
            .lineLimit(1)
            .padding(.horizontal, CoreTileLook.labelInset)
            .frame(height: CoreTileLook.labelHeight)
            GraphView(series: [GraphSeries(values: values, color: color)], maxValue: top, lineWidth: CoreTileLook.lineWidth, glows: true,
                      cornerRadius: CoreTileLook.cornerRadius - 1)
                .padding([.horizontal, .bottom], 1)
        }
        .background(LinearGradient(colors: [color.opacity(CoreTileLook.washTop(usage)), color.opacity(CoreTileLook.washFoot)],
                                   startPoint: .top, endPoint: .bottom), in: shape)
        .overlay(shape.strokeBorder(color.opacity(CoreTileLook.border(usage))))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(cpu)")
        .accessibilityValue(Format.percent(usage))
    }
}
