import OTMKit
import SwiftUI

struct DetailHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.largeTitle.weight(.semibold))
            Spacer()
            Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The apps using the most of one resource, with bars relative to the leader.
struct TopAppsCard: View {
    @Environment(AppModel.self) private var model
    var title: String
    var symbol: String
    var color: Color
    var groups: [ProcessNode]
    var metric: (ProcessTotals) -> Double
    var format: (ProcessTotals) -> String
    /// Values below this round to zero and aren't worth a row.
    var minimum: Double = 0

    var body: some View {
        let top = groups.filter { metric($0.totals) > minimum }.sorted { metric($0.totals) > metric($1.totals) }.prefix(6)
        let peak = top.first.map { metric($0.totals) } ?? 1
        Card {
            Label("Top \(title)", systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
            if top.isEmpty {
                Text("Quiet right now.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(Array(top), id: \.id) { group in
                    if let process = group.process {
                        ProcessBarRow(
                            icon: IconCache.icon(for: process, app: model.regularApps[process.pid]),
                            name: model.displayName(for: process),
                            value: format(group.totals),
                            fraction: metric(group.totals) / max(peak, .leastNonzeroMagnitude),
                            color: color
                        )
                    }
                }
            }
        }
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
                    Text(item.value).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                .font(.subheadline)
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
    /// Samples across the chart, for its time axis; nil for charts that aren't over time.
    var span: Int? = AppModel.graphSpan
    @ViewBuilder var chart: Chart

    var body: some View {
        Card(tint: tint) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(trailing).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(spacing: 3) {
                chart
                if let span { TimeAxis(samples: span) }
            }
            if !legend.isEmpty { ChartLegend(items: legend) }
        }
    }
}

extension View {
    /// The plot area look shared by detail charts: a tinted wash and a hairline border.
    func chartFrame(height: CGFloat, tint: Color) -> some View {
        frame(height: height)
            .background(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)))
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
