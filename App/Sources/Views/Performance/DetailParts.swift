import OTMKit
import SwiftUI

/// Plot heights on the detail pages. Kept modest so that in the default
/// window the header, the key readings, the main graph and the first
/// breakdown are on screen together.
enum DetailGraph {
    /// The resource's main graph.
    static let primary: CGFloat = 200
    /// Breakdowns and other full-width graphs below it.
    static let secondary: CGFloat = 130
    /// Graphs in cards that share a row, and small multiples such as each core tier.
    static let compact: CGFloat = 100
}

struct DetailHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // In a narrow pane the subtitle gives way, not the title.
            Text(title).font(.largeTitle.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Spacer()
            Text(subtitle).font(.title3).foregroundStyle(.secondaryText).lineLimit(1).help(subtitle)
        }
    }
}

/// A resource's key readings in one band under the header, so they sit
/// beside the main graph instead of below the fold. The readings stay on one
/// line while they fit and wrap into even rows when the pane is narrow.
struct MetricStrip<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        FlowRow(spacing: 18, lineSpacing: 10) { content }
            .environment(\.statMinWidth, 60)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.22)))
    }
}

/// The apps using the most of one resource, with bars relative to the leader.
///
/// Only apps whose figure reads as more than zero get a row; under them one
/// line says the rest are idle, and Show all opens Processes sorted by the
/// same figure. The list keeps room for the most rows it needed lately
/// (`TopListRoom`), so the card doesn't change height as apps go idle and
/// busy from one tick to the next.
struct TopAppsCard: View {
    private static let limit = 6
    private static let spacing: CGFloat = 4

    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page: Page = .overview
    /// The room kept for rows, worked out while the body is, like `AutoScaleBounds`.
    @State private var room = TopListRoomHolder(limit: TopAppsCard.limit)
    var title: String
    var symbol: String
    var color: Color
    var groups: [ProcessNode]
    var metric: (ProcessTotals) -> Double
    var format: (ProcessTotals) -> String
    /// The Processes column Show all sorts by.
    var column: ProcessSortKey
    /// Values at or below this aren't worth a row even where they don't read
    /// as zero, and `cutoff` says so: Energy leaves out apps under 10 mW.
    var minimum: Double = 0
    var cutoff: String?
    /// Why there's no ranking, when this Mac doesn't measure the metric at
    /// all. Without it, every app would read 0 and the card "quiet".
    var unavailable: String?

    var body: some View {
        let ranked = unavailable == nil ? groups.filter { $0.process != nil && metric($0.totals) > minimum } : []
        let sorted = ranked.sorted { metric($0.totals) > metric($1.totals) }
        let zero = format(ProcessTotals())
        let top = sorted.prefix(TopListRoom.listed(sorted.lazy.map { format($0.totals) }, zero: zero, limit: Self.limit))
        let peak = top.first.map { metric($0.totals) } ?? 1
        Card {
            header
            if let unavailable {
                UnavailableNote(text: unavailable)
            } else {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(Array(top), id: \.id) { group in
                        if let process = group.process {
                            ProcessBarRow(
                                icon: IconCache.icon(for: process, app: model.regularApps[process.pid]),
                                name: model.displayName(for: process),
                                value: format(group.totals),
                                fraction: metric(group.totals) / max(peak, .leastNonzeroMagnitude),
                                color: color
                            )
                            .frame(height: ProcessBarRow.height)
                        }
                    }
                    if top.count < Self.limit {
                        Text(top.isEmpty ? "Every app is idle" : "Everything else is idle")
                            .font(.explanation)
                            .foregroundStyle(.secondaryText)
                            .padding(.horizontal, 6)
                            .frame(height: ProcessBarRow.height)
                            .help(cutoff.map { "Apps under \($0) aren't listed." } ?? "Apps that would read \(zero) aren't listed.")
                    }
                }
                // With nothing listed, the line sits in the middle of the room
                // kept, as the card's empty state.
                .frame(maxWidth: .infinity, minHeight: Self.height(rows: room.rows(listed: top.count)),
                       alignment: top.isEmpty ? .center : .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Top \(title)", systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
            Spacer(minLength: 8)
            if unavailable == nil {
                Button("Show all", action: showAll)
                    .buttonStyle(.link)
                    .font(.explanation)
                    .help("Every app in Processes, sorted by \(title)")
            }
        }
    }

    private static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * ProcessBarRow.height + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// Every app, busiest first, in the Processes table.
    private func showAll() {
        UserDefaults.standard.set(column.rawValue, forKey: "processSortKey")
        UserDefaults.standard.set(false, forKey: "processSortAscending")
        page = .processes
    }
}

/// A `TopListRoom` kept across a card's updates without being observed: the
/// room is worked out while the card's body is, once per sample, and
/// changing it mustn't ask for another pass.
@MainActor
final class TopListRoomHolder {
    private var room: TopListRoom

    init(limit: Int) {
        room = TopListRoom(limit: limit)
    }

    func rows(listed: Int) -> Int {
        room.update(listed: listed, at: ProcessInfo.processInfo.systemUptime)
    }
}

/// Says a reading isn't available on this Mac, so it isn't mistaken for a
/// measured zero.
struct UnavailableNote: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondaryText)
    }
}

/// A reading this Mac doesn't measure, as an item in a `MetricStrip`: its
/// label, and in place of a figure a short note, with the reason on hover.
/// It takes a line of the strip where a whole card would say less.
struct CapabilityNote: View {
    /// A `Stat` figure's line, so the note sits level with the figures beside it.
    private static let figureHeight = NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .title3))

    var label: String
    var text: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.subheadline).foregroundStyle(.secondaryText)
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .frame(minHeight: Self.figureHeight)
        }
        .help(detail)
    }
}

/// What to say where a reading isn't measured on this Mac.
enum Unavailable {
    static let gpuUtilization = "Utilization not reported"
    static let gpuUtilizationShort = "Not reported by this GPU"
    static let gpuUtilizationDetail = "This GPU's driver doesn't report how busy it is."
    static let energy = "This Mac doesn't report energy use per app."
    static let processNetwork = "Traffic per app isn't available: nettop couldn't run."
    /// Marks a reading this Mac never gives where a graph or figure would be,
    /// so it isn't taken for one not recorded yet (`UnrecordedLook`'s hatch).
    static let symbol = "slash.circle"
}

extension GPUSample {
    /// The GPU's name where it says more than the "GPU" beside it: a
    /// paravirtual GPU's name is just that.
    var tellingName: String? {
        name.caseInsensitiveCompare("GPU") == .orderedSame ? nil : name
    }
}

/// One entry in a chart legend: swatch, name and the current value.
struct LegendItem: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let value: String
    var icon: NSImage?
}

/// Legend under a chart, flowing into as many columns as fit.
struct ChartLegend: View {
    var items: [LegendItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(item.color.gradient)
                        .frame(width: 10, height: 10)
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(item.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    Spacer(minLength: 4)
                    Text(item.value).monospacedDigit().foregroundStyle(.secondaryText).fixedSize()
                }
                .font(.tableText)
            }
        }
    }
}

/// A titled card around a chart, with a legend underneath.
struct ChartCard<Chart: View>: View {
    var title: String
    var trailing = ""
    var tint: Color
    var legend: [LegendItem] = []
    /// A chart over time, with a time axis for the page's window under it.
    var timed = true
    /// The detail's main graph, whose time axis holds the page's Fit
    /// collected data toggle (`GraphFitToggle`).
    var offersFit = false
    @ViewBuilder var chart: Chart

    var body: some View {
        Card(tint: tint) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(trailing).font(.callout).foregroundStyle(.secondaryText).monospacedDigit()
            }
            VStack(spacing: 3) {
                chart
                if timed { TimeAxis(offersFit: offersFit) }
            }
            if !legend.isEmpty { ChartLegend(items: legend) }
        }
    }
}

extension View {
    /// The plot area look shared by detail charts: a tinted wash and a hairline border.
    func chartFrame(height: CGFloat, tint: Color) -> some View {
        frame(height: height).plotFrame(tint: tint)
    }
}

/// A bar split into coloured segments by share of the total.
struct ShareBar: View {
    var segments: [(color: Color, value: Double)]

    var body: some View {
        let total = segments.reduce(0) { $0 + max($1.value, 0) }
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let share = total > 0 ? max(segment.value, 0) / total : 0
                    if share > 0.002 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [segment.color, segment.color.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                            .frame(width: max((geometry.size.width - CGFloat(segments.count - 1) * 2) * share, 2))
                    }
                }
            }
        }
    }
}
