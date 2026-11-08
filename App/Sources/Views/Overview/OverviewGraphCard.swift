import OTMKit
import SwiftUI

/// An Overview card that is mostly its graph: the reading and a few facts in
/// its heading, a key to the graph's lines, then the graph across the card's
/// full width, growing to whatever height its row gives it, over the page's
/// window (`graphWindow`), with the time axis under it.
struct OverviewGraphCard<Chart: View>: View {
    /// The headline figure's size: big enough to read across a room.
    static var headlineFont: NSFont { NSFont.numeric(size: 26, weight: .semibold, rounded: true) }

    var title: String
    var symbol: String
    var tint: Color
    /// 0...1: how strongly the card glows, as its load.
    var glow: Double = 0
    /// The figure beside the title, counted to each reading.
    var headline: Headline?
    /// A line after the headline, cut short in a narrow card.
    var facts = ""
    /// The key to the graph's lines, under the heading; none for a graph of one line.
    var keys: [ChartKey] = []
    /// The least the graph's plot is drawn at.
    var chartHeight: CGFloat
    @ViewBuilder var chart: Chart

    struct Headline {
        var value: Double
        var format: (Double) -> String
        /// The widest the figure gets ("100%"), so the facts beside it don't
        /// shift each time a digit comes or goes.
        var widest: String
    }

    var body: some View {
        Card(tint: tint, glow: glow) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                if let headline {
                    let font = Self.headlineFont
                    // Negative: the glyphs' baseline sits this far above the view's foot.
                    let descender = font.descender
                    AnimatedNumber(value: headline.value, format: headline.format, font: font)
                        .frame(width: ceil(GlyphCache.width(of: headline.widest, font: font)) + 1, alignment: .leading)
                        .alignmentGuide(.firstTextBaseline) { $0.height + descender }
                }
                if !facts.isEmpty {
                    Text(facts)
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(facts)
                }
                Spacer(minLength: 0)
            }
            if !keys.isEmpty { ChartKeyRow(keys: keys) }
            VStack(spacing: 3) {
                chart
                    .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: .infinity)
                    .plotFrame(tint: tint, wash: (0.08, 0.02), border: 0.22)
                TimeAxis()
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// One line or band of an Overview graph, in its key: a sample of how it's
/// drawn, so two lines never differ by colour alone, its name and its reading.
struct ChartKey: Identifiable {
    enum Mark {
        /// A solid line with the area under it filled.
        case line
        /// A dashed line, drawn over the filled one.
        case dashed
        /// A filled band of a stack.
        case band
    }

    var id: String { name }
    var name: String
    var color: Color
    var mark: Mark = .line
    /// The reading in small text after the name.
    var value: String?
    /// Or the reading as a figure that counts to each value, at the size of
    /// a card's main readings (Disk's and Network's rates).
    var figure: Figure?
    /// What the line is, on hover.
    var help: String?

    struct Figure {
        var value: Double
        var format: (Double) -> String
    }
}

/// A graph's keys in a row, wrapping in a narrow card.
struct ChartKeyRow: View {
    private static let figureFont = NSFont.numeric(size: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .medium)

    var keys: [ChartKey]

    var body: some View {
        FlowRow(spacing: 16, lineSpacing: 4, spreads: false) {
            ForEach(keys) { key in
                HStack(alignment: .center, spacing: 6) {
                    KeyMark(color: key.color, mark: key.mark)
                    Text(key.name).foregroundStyle(.secondaryText)
                    if let figure = key.figure {
                        // Room for a typical rate, so the next key doesn't shift with each digit.
                        AnimatedNumber(value: figure.value, format: figure.format, font: Self.figureFont)
                            .frame(minWidth: 92, alignment: .leading)
                    } else if let value = key.value {
                        Text(value).monospacedDigit()
                    }
                }
                .lineLimit(1)
                .help(key.help ?? key.name)
            }
        }
        .font(.metadata)
    }
}

/// How a key's line or band is drawn on its graph.
private struct KeyMark: View {
    var color: Color
    var mark: ChartKey.Mark

    var body: some View {
        switch mark {
        case .band:
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color.gradient)
                .frame(width: 10, height: 10)
        case .line, .dashed:
            Path { path in
                path.move(to: CGPoint(x: 1, y: 1.5))
                path.addLine(to: CGPoint(x: 15, y: 1.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: mark == .dashed ? [3.5, 3] : []))
            .frame(width: 16, height: 3)
        }
    }
}
