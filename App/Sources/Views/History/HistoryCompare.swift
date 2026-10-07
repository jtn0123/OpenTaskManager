import OTMKit
import SwiftUI

/// Two stretches of the timeline being compared: A, the one looked at, and
/// B, what it's compared with, which is the same length just before A
/// until another is picked. A drag along the rail picks whichever is being
/// picked, A first.
struct HistoryCompareDraft: Equatable {
    enum Side {
        case a
        case b
    }

    var a: ClosedRange<Date>?
    /// Nil compares A with the same length just before it.
    var b: ClosedRange<Date>?
    /// Which one a drag along the rail picks.
    var picking = Side.a

    /// What A is compared with.
    var resolvedB: ClosedRange<Date>? { b ?? a.map(HistoryComparison.before) }

    /// Starts with `selection` (a picked session, say) as A, then picks B; else picks A.
    init(selection: ClosedRange<Date>? = nil) {
        a = selection
        picking = selection == nil ? .a : .b
    }

    /// The stretch from one moment picked on the rail to another: from the
    /// start of the earlier one's point, so its records are in it, to the
    /// later one.
    static func stretch(from: Date, to: Date, bucket: TimeInterval) -> ClosedRange<Date> {
        min(from, to).addingTimeInterval(-bucket)...max(from, to)
    }

    static let tintA = Color.teal
    static let tintB = Color.gray

    static func tint(_ side: Side) -> Color { side == .a ? tintA : tintB }
}

/// The comparison card over the charts, while two stretches are compared.
/// It alone reads the comparison, so picking stretches never redraws the
/// charts.
struct HistoryComparisonSlot: View {
    let scrubber: HistoryScrubber
    let recorder: FlightRecorder?
    /// Seconds each point averages.
    let bucket: TimeInterval
    /// The latest point, so a live comparison reads again as records arrive.
    let revision: Date?

    var body: some View {
        if let draft = scrubber.compare {
            HistoryComparisonCard(draft: draft, recorder: recorder, bucket: bucket, revision: revision)
        }
    }
}

/// A against B, figure by figure: each one's average and peak, or total and
/// peak, side by side with how A differs; the apps busier in A; and the
/// events in each. Gaps are left out of every figure, and it says so.
private struct HistoryComparisonCard: View {
    @Environment(AppModel.self) private var model
    let draft: HistoryCompareDraft
    let recorder: FlightRecorder?
    let bucket: TimeInterval
    let revision: Date?

    @State private var comparison: HistoryComparison?
    @State private var busier: [HistoryComparison.AppChange] = []
    @State private var events: (a: [HistoryEvent], b: [HistoryEvent]) = ([], [])

    private struct LoadKey: Equatable {
        let a: ClosedRange<Date>?
        let b: ClosedRange<Date>?
        let recording: URL?
        let revision: Date?
    }

    var body: some View {
        Card(tint: HistoryCompareDraft.tintA) {
            HStack(alignment: .firstTextBaseline) {
                Label("Compare", systemImage: "rectangle.split.2x1")
                    .font(.headline)
                    .foregroundStyle(HistoryCompareDraft.tintA)
                Spacer(minLength: 0)
            }
            if let a = draft.a, let b = draft.resolvedB {
                interval(.a, a, sampled: comparison?.a.sampledSeconds, note: nil)
                interval(.b, b, sampled: comparison?.b.sampledSeconds, note: draft.b == nil ? "the same length before A" : nil)
                Divider()
                if let comparison {
                    table(comparison)
                    Divider()
                    extras(comparison)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(footnote)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Drag along the timeline to pick A, the stretch to look at. It's compared with the same length "
                    + "just before it, or drag again to pick B.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: LoadKey(a: draft.a, b: draft.resolvedB, recording: recorder?.url, revision: revision)) {
            await load()
        }
    }

    /// "A  10:02 – 10:17 AM · 15 min span · 12 min sampled".
    private func interval(_ side: HistoryCompareDraft.Side, _ range: ClosedRange<Date>, sampled: TimeInterval?,
                          note: String?) -> some View {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let coverage = sampled.map { HistoryInterval.coverage(span: span, sampled: $0) } ?? Format.roughDuration(span) + " span"
        // A narrow card wraps it between its parts, never inside "8 min sampled".
        let parts = coverage.components(separatedBy: " · ").map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            HistoryCompareBadge(side: side)
            (Text(HistorySessionStyle.span(range.lowerBound, range.upperBound)).fontWeight(.medium)
                + Text(note.map { " (\($0))" } ?? "") + Text(" · " + parts.joined(separator: " · ")).foregroundStyle(.secondaryText))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ comparison: HistoryComparison) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("A").gridColumnAlignment(.trailing)
                Text("B").gridColumnAlignment(.trailing)
                Text("Change").gridColumnAlignment(.trailing)
            }
            .font(.explanation.weight(.semibold))
            .foregroundStyle(.secondaryText)
            ForEach(comparison.rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.metric.title(row.statistic)).foregroundStyle(.secondaryText).lineLimit(1)
                    Text(row.a.map { row.metric.format($0, row.statistic) } ?? "—").fontWeight(.medium)
                    Text(row.b.map { row.metric.format($0, row.statistic) } ?? "—")
                    Text(row.change?.label(isFraction: row.metric.isFraction) ?? "—").foregroundStyle(.secondaryText)
                }
                .monospacedDigit()
            }
        }
        .font(.tableText)
    }

    @ViewBuilder private func extras(_ comparison: HistoryComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let format = model.cpuScale.format
            if busier.isEmpty {
                Text("No app used noticeably more CPU in A.")
            } else {
                Text("Busier in A: ").foregroundStyle(.secondaryText)
                    + Text(busier.map { "\($0.name) \(format($0.a)) (B \(format($0.b)))" }.joined(separator: ", "))
            }
            let counts = HistoryComparison.eventCounts(a: events.a, b: events.b)
            Text("Events: ").foregroundStyle(.secondaryText)
                + Text("A \(HistoryEventStyle.counts(counts.map { ($0.kind, $0.a) })); B \(HistoryEventStyle.counts(counts.map { ($0.kind, $0.b) }))")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footnote: String {
        "Gaps are left out: averages and peaks cover sampled time only, and totals add up only that time, so a gap counts "
            + "as nothing rather than as zero. A peak is the busiest \(HistoryInterval.adjective(FlightRecorder.span)) record "
            + "(for CPU, its busiest update)."
    }

    private func load() async {
        guard let recorder, let a = draft.a, let b = draft.resolvedB else {
            comparison = nil
            return
        }
        // Wait for a drag to settle before reading.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        guard let first = try? await recorder.stats(from: a.lowerBound, to: a.upperBound),
              let second = try? await recorder.stats(from: b.lowerBound, to: b.upperBound) else { return }
        let appsA = (try? await recorder.topCPU(from: a.lowerBound, to: a.upperBound, count: 20)) ?? []
        let appsB = (try? await recorder.topCPU(from: b.lowerBound, to: b.upperBound, count: 40)) ?? []
        let eventsA = (try? await recorder.events(from: a.lowerBound, to: a.upperBound)) ?? []
        let eventsB = (try? await recorder.events(from: b.lowerBound, to: b.upperBound)) ?? []
        guard !Task.isCancelled else { return }
        comparison = HistoryComparison(a: first, b: second)
        busier = HistoryComparison.busier(a: appsA, b: appsB, count: 3)
        events = (eventsA, eventsB)
    }
}

/// "A" or "B" in its tint, as the rail and the charts mark the stretch.
struct HistoryCompareBadge: View {
    let side: HistoryCompareDraft.Side

    var body: some View {
        Text(side == .a ? "A" : "B")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(HistoryCompareDraft.tint(side)))
            .accessibilityLabel(side == .a ? "Stretch A" : "Stretch B")
    }
}

/// The compare lane while a comparison has a stretch to show; nothing
/// otherwise. It alone reads the comparison, so a drag picking A or B
/// redraws the lane and not the rest of the rail.
struct HistoryCompareLaneSlot: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>

    var body: some View {
        if let draft = scrubber.compare, draft.a != nil {
            HistoryCompareLane(draft: draft, domain: domain)
        }
    }
}

/// A and B as bands over the rail's track, each lettered, while a
/// comparison is open.
private struct HistoryCompareLane: View {
    let draft: HistoryCompareDraft
    let domain: ClosedRange<Date>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Color.clear.frame(width: width, height: 1)
                if let b = draft.resolvedB {
                    band(.b, b, width: width)
                }
                if let a = draft.a {
                    band(.a, a, width: width)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: 18)
    }

    @ViewBuilder private func band(_ side: HistoryCompareDraft.Side, _ range: ClosedRange<Date>, width: CGFloat) -> some View {
        if range.upperBound >= domain.lowerBound, range.lowerBound <= domain.upperBound {
            let lower = HistoryMoment.x(of: max(range.lowerBound, domain.lowerBound), width: width, domain: domain)
            let upper = HistoryMoment.x(of: min(range.upperBound, domain.upperBound), width: width, domain: domain)
            let length = max(upper - lower, 16)
            let tint = HistoryCompareDraft.tint(side)
            let picking = draft.picking == side
            Text(side == .a ? "A" : "B")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 5)
                .frame(width: length, height: 16, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: picking ? 1.5 : 1, dash: side == .b && draft.b == nil ? [3, 2] : [])))
                .alignmentGuide(.leading) { _ in -min(lower, width - length) }
                .help(side == .a ? "A: \(HistorySessionStyle.span(range.lowerBound, range.upperBound))"
                    : "B: \(HistorySessionStyle.span(range.lowerBound, range.upperBound))"
                        + (draft.b == nil ? ", the same length just before A" : ""))
        }
    }
}

/// The row under the rail while comparing: which stretch a drag picks, a
/// way back to comparing with the same length before A, and Done.
struct HistoryCompareControls: View {
    let scrubber: HistoryScrubber

    var body: some View {
        if let draft = scrubber.compare {
            HStack(spacing: 8) {
                chip(.a, draft.a, picking: draft.picking == .a)
                chip(.b, draft.resolvedB, picking: draft.picking == .b)
                if draft.b != nil {
                    Button {
                        scrubber.compare?.b = nil
                        scrubber.compare?.picking = .b
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Text("Same Length Before A")
                            Text("Before A")
                        }
                    }
                    .help("Compare A with the same length of time just before it")
                }
                Spacer(minLength: 0)
                Button("Done") { scrubber.compare = nil }
                    .fixedSize()
                    .help("Close the comparison")
            }
        }
    }

    /// A stretch's letter and span; clicking it makes the next drag pick it.
    private func chip(_ side: HistoryCompareDraft.Side, _ range: ClosedRange<Date>?, picking: Bool) -> some View {
        Button {
            scrubber.compare?.picking = side
        } label: {
            HStack(spacing: 5) {
                HistoryCompareBadge(side: side)
                Text(range.map { HistorySessionStyle.span($0.lowerBound, $0.upperBound) } ?? "Drag to pick")
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .tint(picking ? HistoryCompareDraft.tint(side) : nil)
        .layoutPriority(-1)
        .help(picking ? "Drag along the timeline to pick \(side == .a ? "A" : "B")"
            : "Click, then drag along the timeline, to pick \(side == .a ? "A" : "B") again")
    }
}
