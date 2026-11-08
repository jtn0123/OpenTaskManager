import AppKit
import OTMKit
import SwiftUI

/// How the History page shows a stretch with nothing recorded: the neutral
/// wash and faint hatch of a live graph's unrecorded stretch (`UnrecordedLook`),
/// so a gap never reads as the values dropping.
enum HistoryGapStyle {
    static func wash(dark: Bool) -> Color {
        Color(nsColor: .windowBackgroundColor).opacity(UnrecordedLook.washOpacity(dark: dark))
    }

    static func hatch(dark: Bool) -> Color {
        Color(nsColor: .labelColor).opacity(UnrecordedLook.hatchOpacity(dark: dark))
    }

    /// The edges of a gap the pointer is over.
    static func edge(dark: Bool) -> Color {
        Color(nsColor: .labelColor).opacity(UnrecordedLook.edgeOpacity(dark: dark))
    }

    /// "2 min 24 s", or "3 h 10 min" for a long one.
    static func duration(_ gap: HistoryGap) -> String {
        gap.duration < 3_600 ? Format.timeSpan(gap.duration) : Format.roughDuration(gap.duration)
    }

    /// "10:12:06 – 10:14:30 AM · 2 min 24 s".
    static func describe(_ gap: HistoryGap) -> String {
        HistorySessionStyle.span(gap.start, gap.end) + " · " + duration(gap)
    }
}

/// What a page's charts draw for its gaps, worked out once per load (and
/// width) for all of them: each gap's empty stretch, from where a line
/// breaks off to where it picks up, washed, with a fade either side for the
/// fills to dissolve into; the points either side, which get a dot there;
/// and how wide a gap counts for the pointer, so a hairline one can still
/// be found.
struct HistoryGapMarks {
    /// The gaps, with the times they're described by.
    let gaps: [HistoryGap]
    /// Each of `gaps` as the graphs leave it empty (`HistoryGap.drawn`).
    let drawn: [HistoryGap]
    let shades: [HistoryGap.Shade]
    /// Indices of the points that border a gap.
    let borders: [Int]
    /// The seconds a gap is widened to under the pointer: about 8 points.
    let target: TimeInterval
    /// The seconds a run of readings must span to be filled under: about 8
    /// points, less of which reads as a bar (`HistoryPoint.unfilled`).
    let narrowestFill: TimeInterval

    init(gaps: [HistoryGap], points: [HistoryPoint], bucket: TimeInterval, domain: ClosedRange<Date>, plotWidth: CGFloat) {
        let perPoint = domain.upperBound.timeIntervalSince(domain.lowerBound) / Double(max(plotWidth, 1))
        self.gaps = gaps
        drawn = gaps.map { $0.drawn(in: points) }
        shades = HistoryGap.shading(drawn, fade: 6 * perPoint, within: domain)
        borders = HistoryGap.borders(of: gaps, in: points, bucket: bucket)
        target = 8 * perPoint
        narrowestFill = 8 * perPoint
    }

    /// The gap whose empty stretch is at `time`, as the pointer finds it.
    func gap(at time: Date) -> HistoryGap? {
        drawn.firstIndex { $0.contains(time, minimumSpan: target) }.map { gaps[$0] }
    }

    /// `gap`'s empty stretch on the graphs.
    func drawn(_ gap: HistoryGap) -> HistoryGap {
        gaps.firstIndex(of: gap).map { drawn[$0] } ?? gap
    }
}

/// The faint diagonal hatch across a chart's gaps, over its plot. It's drawn
/// with the chart, so only a load or a resize redraws it.
struct HistoryGapHatch: View {
    let gaps: [HistoryGap]
    let domain: ClosedRange<Date>
    @Environment(\.colorScheme) private var colorScheme

    private static let spacing = UnrecordedLook.hatchSpacing

    var body: some View {
        Canvas { context, size in
            var clip = Path()
            for gap in gaps {
                let start = HistoryMoment.x(of: gap.start, width: size.width, domain: domain)
                let end = HistoryMoment.x(of: gap.end, width: size.width, domain: domain)
                if end - start >= 1 { clip.addRect(CGRect(x: start, y: 0, width: end - start, height: size.height)) }
            }
            guard !clip.isEmpty else { return }
            context.clip(to: clip)
            var diagonals = Path()
            var x = -size.height
            while x < size.width + Self.spacing {
                diagonals.move(to: CGPoint(x: x, y: 0))
                diagonals.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += Self.spacing
            }
            context.stroke(diagonals, with: .color(HistoryGapStyle.hatch(dark: colorScheme == .dark)), lineWidth: UnrecordedLook.hatchWidth)
        }
        .allowsHitTesting(false)
    }
}

/// The range's gaps, counted on the coverage line under the title, each a
/// click away: its start, end and length, and picking one pins the moment
/// recording picked up again and outlines the gap on the timeline and the
/// charts. The longest are listed when there are many.
struct HistoryGapsMenu: View {
    let gaps: [HistoryGap]
    let points: [HistoryPoint]
    let bucket: TimeInterval
    let scrubber: HistoryScrubber

    private static let listed = 30

    var body: some View {
        let shown = gaps.sorted { $0.duration > $1.duration }.prefix(Self.listed).sorted { $0.start < $1.start }
        Menu {
            Section("Not recorded") {
                ForEach(shown) { gap in
                    Button(HistoryGapStyle.describe(gap)) { pin(after: gap) }
                }
            }
            if gaps.count > shown.count {
                Text("\(gaps.count - shown.count) shorter gaps not listed")
            }
        } label: {
            Text(gaps.count == 1 ? "1 gap" : "\(gaps.count) gaps")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Takes back the button's own inset, so the dots either side on the coverage line sit evenly.
        .padding(.horizontal, -2)
        .help("Stretches with nothing recorded: the app wasn't running, the Mac slept, or updates were paused. "
            + "The graphs and the timeline hatch them, and every figure leaves them out. "
            + "Pick one to pin the moment recording picked up again.")
    }

    /// Pins the first point after `gap`, or the last before one at the end,
    /// and outlines the gap.
    private func pin(after gap: HistoryGap) {
        let after = points.first { $0.time > gap.end } ?? points.last { $0.time <= gap.start }
        scrubber.pin(after?.time)
        scrubber.selectedGap = gap
    }
}
