import AppKit
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

    static func letter(_ side: Side) -> String { side == .a ? "A" : "B" }
}

/// The comparison's summary under the rail, while two stretches are
/// compared. It alone reads the comparison, so picking stretches never
/// redraws the charts.
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

/// A against B at a glance: each stretch's times, how much of it was
/// sampled and the gaps left out, then the average and peak of CPU,
/// memory, disk and network in both, with how A differs. Every figure
/// (totals, power and GPU), the apps busier in A and the events in each
/// are a click away. Gaps are left out of every figure, and it says so.
private struct HistoryComparisonCard: View {
    @Environment(AppModel.self) private var model
    let draft: HistoryCompareDraft
    let recorder: FlightRecorder?
    let bucket: TimeInterval
    let revision: Date?
    /// Every figure shown under the headline ones.
    @AppStorage("historyCompareDetails") private var showsDetails = false

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
            if let a = draft.a, let b = draft.resolvedB {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        interval(.a, a, stats: comparison?.a, note: nil)
                        interval(.b, b, stats: comparison?.b, note: draft.b == nil ? "before A" : nil)
                    }
                    Spacer(minLength: 0)
                    detailsButton
                }
                if let comparison {
                    // B's own figures while there's room, else A's and the change.
                    ViewThatFits(in: .horizontal) {
                        headlines(comparison, showsB: true)
                        headlines(comparison, showsB: false)
                    }
                    Text("Disk and network add both directions. Gaps are left out of every figure.")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDetails {
                        Divider()
                        table(comparison)
                        Divider()
                        extras
                        Text(footnote)
                            .font(.explanation)
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
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

    private var detailsButton: some View {
        Button {
            showsDetails.toggle()
        } label: {
            Label(showsDetails ? "Fewer Figures" : "All Figures", systemImage: showsDetails ? "chevron.up" : "chevron.down")
        }
        .controlSize(.small)
        .fixedSize()
        .help(showsDetails ? "Show only the headline figures"
            : "Show every figure (totals, peaks, power and GPU where recorded), the apps busier in A and the events in each")
    }

    /// "A  10:02 – 10:17 AM · 15 min span · 12 min sampled · 3 min of gaps left out".
    private func interval(_ side: HistoryCompareDraft.Side, _ range: ClosedRange<Date>, stats: HistoryIntervalStats?,
                          note: String?) -> some View {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        var parts = [Format.roughDuration(span) + " span"]
        if let stats {
            parts.append(Format.roughDuration(min(stats.sampledSeconds, span)) + " sampled")
            parts.append(HistoryInterval.leftOut(span: span, sampled: stats.sampledSeconds))
        }
        // A narrow card wraps it between its parts, never inside "8 min sampled".
        let joined = parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            HistoryCompareBadge(side: side)
            (Text(HistorySessionStyle.span(range.lowerBound, range.upperBound)).fontWeight(.medium)
                + Text(note.map { " (\($0))" } ?? "") + Text(" · " + joined).foregroundStyle(.secondaryText))
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// CPU, memory, disk and network: each one's average and peak in A,
    /// in B when `showsB`, and how A differs.
    private func headlines(_ comparison: HistoryComparison, showsB: Bool) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Average").gridCellColumns(showsB ? 3 : 2).gridCellAnchor(.leading)
                Text("Peak").gridCellColumns(showsB ? 3 : 2).gridCellAnchor(.leading).padding(.leading, 10)
            }
            .font(.explanation.weight(.semibold))
            .foregroundStyle(.secondaryText)
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(0..<2, id: \.self) { group in
                    HistoryCompareBadge(side: .a).padding(.leading, group == 1 ? 10 : 0)
                    if showsB { HistoryCompareBadge(side: .b) }
                    Text("Change").font(.explanation.weight(.semibold)).foregroundStyle(.secondaryText)
                }
            }
            ForEach(comparison.headlines) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.headline.name)
                        .foregroundStyle(.secondaryText)
                        .gridColumnAlignment(.leading)
                        .help(row.headline.parts.map { "\(row.headline.name): \($0) together" } ?? row.headline.name)
                    figures(row, .average, showsB: showsB)
                    figures(row, .peak, showsB: showsB, lead: 10)
                }
                .monospacedDigit()
            }
        }
        .font(.tableText)
        .fixedSize()
    }

    /// One statistic's cells in a headline row: A, B when `showsB`, the
    /// change; `lead` sets the group off from the one before.
    @ViewBuilder private func figures(_ row: HistoryComparison.Headline, _ statistic: HistoryStatistic, showsB: Bool,
                                      lead: CGFloat = 0) -> some View {
        Text(row.text(row.a, statistic)).fontWeight(.medium).padding(.leading, lead)
        if showsB { Text(row.text(row.b, statistic)) }
        Text(row.changeText(statistic)).foregroundStyle(.secondaryText)
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

    private var extras: some View {
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
        "Averages and peaks cover sampled time only, and totals add up only that time, so a gap counts "
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
    var size: CGFloat = 16

    var body: some View {
        Text(HistoryCompareDraft.letter(side))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 4).fill(HistoryCompareDraft.tint(side)))
            .accessibilityLabel(side == .a ? "Stretch A" : "Stretch B")
    }
}

/// A or B as the rail draws it: where its bracket goes across the rail,
/// which label it wears, and on which row (`CompareBrackets` in OTMKit).
struct HistoryCompareBracket: Identifiable {
    let side: HistoryCompareDraft.Side
    let range: ClosedRange<Date>
    let placement: CompareBrackets.Placement
    /// The label's times; empty for the letter alone.
    let label: String
    /// B, while it's the same length before A rather than picked.
    let isDefault: Bool
    let isPicking: Bool

    var id: String { HistoryCompareDraft.letter(side) }

    /// The font of the times on a bracket's label, for measuring them.
    private static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
    /// The badge, the gap after it and the label's padding.
    private static let badge: CGFloat = 14

    /// A's and B's brackets across a rail `width` points wide spanning
    /// `domain`, those that reach into it.
    @MainActor
    static func layout(_ draft: HistoryCompareDraft, domain: ClosedRange<Date>, width: CGFloat) -> [HistoryCompareBracket] {
        guard let a = draft.a else { return [] }
        var stretches: [(side: HistoryCompareDraft.Side, range: ClosedRange<Date>)] = [(.a, a)]
        if let b = draft.resolvedB { stretches.append((.b, b)) }
        stretches.removeAll { $0.range.upperBound < domain.lowerBound || $0.range.lowerBound > domain.upperBound }
        let texts = stretches.map { labels(for: $0.range) }
        let placements = CompareBrackets.place(stretches.indices.map { index in
            CompareBrackets.Bracket(lower: Double(HistoryMoment.x(of: stretches[index].range.lowerBound, width: width, domain: domain)),
                                    upper: Double(HistoryMoment.x(of: stretches[index].range.upperBound, width: width, domain: domain)),
                                    labels: texts[index].map { Double(labelWidth($0)) })
        }, width: Double(width))
        return stretches.indices.map { index in
            let side = stretches[index].side
            let placement = placements[index]
            return HistoryCompareBracket(side: side, range: stretches[index].range, placement: placement,
                                         label: texts[index][placement.label], isDefault: side == .b && draft.b == nil,
                                         isPicking: draft.picking == side)
        }
    }

    /// A stretch's labels, widest first: its start and end as the rail
    /// says times, then without AM or PM, then nothing (the letter alone).
    @MainActor
    static func labels(for range: ClosedRange<Date>) -> [String] {
        let fine = range.upperBound.timeIntervalSince(range.lowerBound) < 10 * 60
        let short = fine ? shortTimes.seconds : shortTimes.minutes
        return [HistorySessionStyle.span(range.lowerBound, range.upperBound),
                "\(short.string(from: range.lowerBound))–\(short.string(from: range.upperBound))", ""]
    }

    /// The user's times without AM or PM, to the minute and to the second.
    @MainActor private static let shortTimes = (minutes: shortTime("jmm"), seconds: shortTime("jmmss"))

    private static func shortTime(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = CompareBrackets.withoutDayPeriod(DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .current)
            ?? "h:mm")
        return formatter
    }

    /// How wide a bracket's label is with `text` beside its letter.
    static func labelWidth(_ text: String) -> CGFloat {
        let times = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width) + 5
        return badge + times + 8
    }
}

/// The compare lane while a comparison is open: A and B as brackets over the
/// track, each labelled with its letter and its start and end times, B
/// dashed while it's the same length before A; or, until A is picked, how
/// to pick it. The brackets' sides run on down through the track
/// (`HistoryCompareTrackBands`). It alone reads the comparison, so a drag
/// picking A or B redraws the lane and not the rest of the rail.
struct HistoryCompareLaneSlot: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>

    var body: some View {
        if let draft = scrubber.compare {
            HistoryCompareLane(draft: draft, domain: domain)
        }
    }
}

private struct HistoryCompareLane: View {
    let draft: HistoryCompareDraft
    let domain: ClosedRange<Date>
    @State private var width: CGFloat = 0

    private static let rowHeight: CGFloat = 19
    /// Where a row's line runs, through the middle of its labels.
    private static let line: CGFloat = 8

    var body: some View {
        let brackets = HistoryCompareBracket.layout(draft, domain: domain, width: width)
        let height = CGFloat(CompareBrackets.rows(brackets.map(\.placement))) * Self.rowHeight + 3
        ZStack(alignment: .topLeading) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            if draft.a == nil {
                HStack(spacing: 6) {
                    HistoryCompareBadge(side: .a, size: 14)
                    Text("Drag along the timeline to pick A")
                }
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .fixedSize()
            } else {
                Canvas { context, size in
                    for bracket in brackets {
                        draw(bracket, in: &context, height: size.height)
                    }
                }
                ForEach(brackets) { bracket in
                    label(bracket)
                        .offset(x: CGFloat(bracket.placement.labelX), y: CGFloat(bracket.placement.row) * Self.rowHeight)
                }
            }
        }
        .frame(height: draft.a == nil ? Self.rowHeight : height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The bracket's top along its row and its sides down to the lane's foot.
    private func draw(_ bracket: HistoryCompareBracket, in context: inout GraphicsContext, height: CGFloat) {
        let tint = HistoryCompareDraft.tint(bracket.side)
        // In a point at each end, so A and B side by side keep two sides.
        let lower = CGFloat(bracket.placement.lower) + 1
        let upper = max(CGFloat(bracket.placement.upper) - 1, lower + 1)
        let top = CGFloat(bracket.placement.row) * Self.rowHeight + Self.line
        let round = min(3, (upper - lower) / 2)
        var shape = Path()
        shape.move(to: CGPoint(x: lower, y: height))
        shape.addLine(to: CGPoint(x: lower, y: top + round))
        shape.addQuadCurve(to: CGPoint(x: lower + round, y: top), control: CGPoint(x: lower, y: top))
        shape.addLine(to: CGPoint(x: upper - round, y: top))
        shape.addQuadCurve(to: CGPoint(x: upper, y: top + round), control: CGPoint(x: upper, y: top))
        shape.addLine(to: CGPoint(x: upper, y: height))
        context.fill(Path(CGRect(x: lower, y: top, width: upper - lower, height: height - top)), with: .color(tint.opacity(0.10)))
        context.stroke(shape, with: .color(tint), style: HistoryCompareTrackBands.side(bracket))
    }

    private func label(_ bracket: HistoryCompareBracket) -> some View {
        let tint = HistoryCompareDraft.tint(bracket.side)
        let letter = HistoryCompareDraft.letter(bracket.side)
        return HStack(spacing: 5) {
            HistoryCompareBadge(side: bracket.side, size: 14)
            if !bracket.label.isEmpty {
                Text(bracket.label)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 17)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: bracket.isPicking ? 1.5 : 1))
        .fixedSize()
        .help("\(letter): \(HistorySessionStyle.span(bracket.range.lowerBound, bracket.range.upperBound))"
            + (bracket.isDefault ? ", the same length just before A" : "")
            + (bracket.isPicking ? ". Drag along the timeline to pick it again." : ""))
        .accessibilityLabel("\(letter), \(HistorySessionStyle.span(bracket.range.lowerBound, bracket.range.upperBound))")
    }
}

/// A and B carried down through the rail's track: each stretch tinted, its
/// bracket's sides running on to the track's foot, under the coverage and
/// the handle.
struct HistoryCompareTrackBands: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>
    let width: CGFloat

    var body: some View {
        if let draft = scrubber.compare, draft.a != nil {
            let brackets = HistoryCompareBracket.layout(draft, domain: domain, width: width)
            Canvas { context, size in
                for bracket in brackets {
                    let tint = HistoryCompareDraft.tint(bracket.side)
                    let lower = CGFloat(bracket.placement.lower) + 1
                    let upper = max(CGFloat(bracket.placement.upper) - 1, lower + 1)
                    context.fill(Path(CGRect(x: lower, y: 0, width: upper - lower, height: size.height)), with: .color(tint.opacity(0.16)))
                    var sides = Path()
                    for x in [lower, upper] {
                        sides.move(to: CGPoint(x: x, y: 0))
                        sides.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(sides, with: .color(tint), style: Self.side(bracket))
                }
            }
            .frame(width: width)
            .allowsHitTesting(false)
        }
    }

    /// How a bracket's sides are stroked: heavier while a drag picks it,
    /// dashed while B is the same length before A.
    static func side(_ bracket: HistoryCompareBracket) -> StrokeStyle {
        StrokeStyle(lineWidth: bracket.isPicking ? 2 : 1.5, lineCap: .butt, lineJoin: .round, dash: bracket.isDefault ? [4, 2.5] : [])
    }
}

/// Compare, on or off. Off, it looks like the buttons beside it; on, while
/// a comparison is open, it shows selected, and a click closes it.
struct HistoryCompareToggle: View {
    let scrubber: HistoryScrubber
    /// A picked session, compared as A when the comparison opens.
    var selection: ClosedRange<Date>?

    var body: some View {
        Toggle(isOn: Binding(get: { scrubber.comparing }, set: { on in
            if on {
                scrubber.draft = nil
                scrubber.compare = HistoryCompareDraft(selection: selection)
            } else {
                scrubber.compare = nil
            }
        })) {
            Label("Compare", systemImage: "rectangle.split.2x1")
        }
        .toggleStyle(.button)
        .fixedSize()
        .help(scrubber.comparing ? "Comparing two stretches of the timeline. Click to stop."
            : selection == nil ? "Compare two stretches of the timeline: drag along it to pick A, then B or the same length before A"
            : "Compare this session with the same length just before it, or with another stretch you drag along the timeline")
    }
}

/// The row under the rail while comparing: Compare, selected; which
/// stretch a drag picks; a way back to comparing with the same length
/// before A; and Done.
struct HistoryCompareControls: View {
    let scrubber: HistoryScrubber

    var body: some View {
        if let draft = scrubber.compare {
            HStack(spacing: 8) {
                HistoryCompareToggle(scrubber: scrubber)
                if draft.a != nil {
                    Text("Drag picks")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                        .fixedSize()
                    Picker("Drag picks", selection: Binding(get: { draft.picking }, set: { scrubber.compare?.picking = $0 })) {
                        Text("A").tag(HistoryCompareDraft.Side.a)
                        Text("B").tag(HistoryCompareDraft.Side.b)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Which stretch the next drag along the timeline picks")
                }
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
}
