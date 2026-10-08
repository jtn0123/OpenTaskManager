import AppKit
import OTMKit
import SwiftUI

extension EnvironmentValues {
    /// The Performance detail pane's visible height, which sizes each
    /// device's main graph (`Hero.height`). Changes with the window, not per tick.
    @Entry var detailPaneHeight: CGFloat = 0
}

/// The parts every Performance device page opens with: its title over a
/// level bar with the current figure (`DeviceHeader`), then one card whose
/// main graph fills the pane (`DeviceCard`), with the device's figures in a
/// grid under it. Everything else on the page follows that card.
enum Hero {
    /// What shows around the main graph in the pane: the page's padding,
    /// the title and level bar, the card's caption row, time axis and
    /// divider, and the first row of figures, so they're on screen with it.
    static let reserved: CGFloat = 262
    /// A legend's line under the graph.
    static let legendLine: CGFloat = 24

    /// The main graph's height in a pane `pane` points tall, `extra` more
    /// points of which go to what a page adds around it.
    static func height(pane: CGFloat, extra: CGFloat = 0) -> CGFloat {
        CGFloat(HeroHeight.graph(visible: Double(pane), reserved: Double(reserved + extra)))
    }
}

// MARK: - Title and level

/// A device page's title and subtitle, as `DetailHeader`, over its level
/// bar and current figure.
struct DeviceHeader: View {
    var title: String
    var subtitle: String
    var level: LevelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailHeader(title: title, subtitle: subtitle)
            level
        }
    }
}

/// The level bar and, after it, the figure it shows in the device's
/// colour with a few words on what it is ("busy", "of 16 GB in use").
struct LevelRow: View {
    private static let figureFont = NSFont.numeric(size: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)

    /// 0 to 1; nil leaves the bar dim, for a reading this Mac doesn't give.
    var fraction: Double?
    var color: Color
    /// The figure, counted to each new reading; or `text` where it isn't a number.
    var value: Double?
    var format: (Double) -> String = { Format.percent($0) }
    var text: String?
    var caption: String
    /// What the bar measures, for VoiceOver.
    var label: String
    /// Room for the figure, so its changing width doesn't move the bar.
    var figureWidth: CGFloat = 64

    var body: some View {
        let descent = -Self.figureFont.descender
        return HStack(alignment: .center, spacing: 12) {
            LevelBar(fraction: fraction, color: color, label: label)
                .frame(height: 13)
                .frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if let value {
                        // Its layers have no baseline of their own: the line's is a descent above its foot.
                        AnimatedNumber(value: value, format: format, font: Self.figureFont, color: color)
                            .alignmentGuide(.firstTextBaseline) { $0.height - descent }
                    } else {
                        Text(text ?? "—").font(.title2.weight(.semibold)).foregroundStyle(color).lineLimit(1)
                    }
                }
                .frame(minWidth: figureWidth, alignment: .trailing)
                Text(caption)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Main graph card

/// A device's main card: its caption row, the main graph at the pane's
/// height (`heroPlot`) over the page's time axis, an optional legend, and
/// the device's figures in a grid under a divider.
struct DeviceCard<Caption: View, Plot: View, Figures: View>: View {
    var tint: Color
    var legend: [LegendItem] = []
    /// What the graph holds, where a line of legend can't say it.
    var footnote: String?
    @ViewBuilder var caption: Caption
    @ViewBuilder var plot: Plot
    @ViewBuilder var figures: Figures

    var body: some View {
        Card(tint: tint) {
            caption
            VStack(spacing: 3) {
                plot
                TimeAxis(offersFit: true)
            }
            if !legend.isEmpty { ChartLegend(items: legend) }
            if let footnote {
                Text(footnote).font(.explanation).foregroundStyle(.secondaryText)
            }
            Divider().padding(.vertical, 2)
            DeviceFigures { figures }
                .environment(\.statMinWidth, 0)
        }
    }
}

/// A main card's caption: its title, and a figure or note at the far end.
struct DeviceCaption: View {
    var title: String
    var trailing = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            Text(trailing).font(.callout).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
        }
    }
}

/// The line over one of a main card's graphs where it holds more than one
/// ("Active time", "Transfer rate"): its name, and its figure at the far end.
struct HeroGraphTitle: View {
    var title: String
    var trailing = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(trailing).monospacedDigit()
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
    }
}

extension View {
    /// A main graph's plot: `height` tall, in a wash of the device's colour
    /// with a border in it. Its graph draws a fine grid of `rows` rows
    /// (`fineGridRows`), whose columns scroll with the data.
    func heroPlot(height: CGFloat, tint: Color, rows: Int = 8) -> some View {
        environment(\.fineGridRows, rows)
            .frame(height: height)
            .plotFrame(tint: tint, wash: (0.13, 0.02), border: 0.5, lineWidth: 1.25)
    }
}

/// Label-over-value figures in even columns, as many as fit at
/// `minimum` points each; a reading that changes width never moves the others.
struct DeviceFigures: Layout {
    var minimum: CGFloat = 128
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 12

    private func columns(width: CGFloat, count: Int) -> (count: Int, width: CGFloat) {
        let fit = FigureColumns.fit(width: Double(width), count: count, minimum: Double(minimum), spacing: Double(spacing))
        return (fit.count, CGFloat(fit.width))
    }

    /// The width the figures take: all of a bounded proposal, or one row of them.
    private func width(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite { return max(width, 0) }
        return CGFloat(FigureColumns.idealWidth(count: count, minimum: Double(minimum), spacing: Double(spacing)))
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, width: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, count: subviews.count)
        let grid = columns(width: width, count: subviews.count)
        let heights = rowHeights(subviews, columns: grid.count, width: grid.width)
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = columns(width: bounds.width, count: subviews.count)
        let heights = rowHeights(subviews, columns: grid.count, width: grid.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<grid.count {
                let index = row * grid.count + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.width + spacing), y: y),
                                      proposal: ProposedViewSize(width: grid.width, height: height))
            }
            y += height + lineSpacing
        }
    }
}
