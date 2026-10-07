import AppKit
import OTMKit
import SwiftUI

/// How saved sessions look and read on the History page.
enum HistorySessionStyle {
    static let tint = Color.orange

    /// The session's note, or "Session" without one.
    static func title(_ session: RecordingSession) -> String {
        session.note.isEmpty ? "Session" : session.note
    }

    /// "10:02 – 10:17 AM": with seconds under ten minutes, and the date when
    /// it isn't today or `dated` asks for it.
    static func span(_ start: Date, _ end: Date, dated: Bool = false) -> String {
        let fine = end.timeIntervalSince(start) < 10 * 60
        let time: Date.FormatStyle = fine ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
        let calendar = Calendar.current
        let startStyle = dated || !calendar.isDateInToday(start) ? time.weekday(.abbreviated).month(.abbreviated).day() : time
        let endStyle = calendar.isDate(start, inSameDayAs: end) ? time : time.weekday(.abbreviated).month(.abbreviated).day()
        return "\(start.formatted(startStyle)) – \(end.formatted(endStyle))"
    }
}

extension HistoryMoment {
    /// How the rail's times read across `domain`: with seconds under twenty
    /// minutes, and the day when the span isn't all today (the weekday this
    /// week, else the date).
    static func railStyle(for domain: ClosedRange<Date>, now: Date = .now) -> Date.FormatStyle {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let style: Date.FormatStyle = span < 20 * 60 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
        let calendar = Calendar.current
        guard !(calendar.isDateInToday(domain.lowerBound) && calendar.isDateInToday(domain.upperBound)) else { return style }
        return now.timeIntervalSince(domain.lowerBound) < 6 * 86_400 ? style.weekday(.abbreviated) : style.month(.abbreviated).day()
    }
}

/// The timeline over the charts. Its track shows which stretches of the
/// range were recorded, its gaps hatched between dashed edges, and its
/// handle carries the moments shown: where playback is ("Playing"), a pinned
/// moment, and one the pointer previews ("Preview"), each its own pill, or
/// "Latest" (a file's "End") at the right end when nothing is picked; over a
/// gap, what wasn't recorded, from when to when. Times run along it below.
/// Clicking or dragging along it moves playback while there is any, and
/// otherwise pins a moment, like the charts; hovering previews one, and a
/// Shift-drag marks a session. While comparing, a drag picks A or B
/// instead, and the card is tinted. A key over it names what the track and
/// the lanes show; saved sessions, the events (in a thin lane of their own)
/// and the stretches compared (as labelled brackets on the track) ride
/// above the track, and the controls to mark, compare, export and play
/// back sit under it. Scrolled down among the charts, it folds to a strip
/// (`HistoryRailStrip`); opened from there, its Fold button folds it again.
///
/// The track spans the same width as the charts' plots, so the handle sits
/// over their markers. Only its handle, the lanes above it and the
/// controls read the scrubber, so none of this redraws the charts.
struct HistoryRail: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let store: HistoryRecordingStore
    /// The live recording, where sessions are saved; nil for a recording
    /// file, which is read-only.
    let recorder: FlightRecorder?
    let points: [HistoryPoint]
    /// The stretches with nothing recorded.
    let gaps: [HistoryGap]
    /// What happened within the range.
    let events: [HistoryEvent]
    let domain: ClosedRange<Date>
    /// Seconds each point averages.
    let bucket: TimeInterval
    /// Folds the card, opened from the strip, back to it; nil shows no control for that.
    var onFold: (() -> Void)?

    var body: some View {
        let hasEvents = events.contains { domain.contains($0.time) }
        let hasSessions = recorder != nil && store.sessions.contains { $0.end >= domain.lowerBound && $0.start <= domain.upperBound }
        // Tinted while comparing, so the mode reads at a glance.
        Card(tint: scrubber.comparing ? HistoryCompareDraft.tintA : nil) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HistoryRailKey(hasEvents: hasEvents, hasSessions: hasSessions)
                    if let onFold {
                        Button(action: onFold) {
                            Label("Fold", systemImage: "chevron.up")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Fold the timeline to a strip while the page is scrolled down among the charts")
                    }
                }
                .padding(.bottom, 3)
                if recorder != nil {
                    HistorySessionLane(scrubber: scrubber, store: store, domain: domain)
                }
                if hasEvents {
                    HistoryEventLane(scrubber: scrubber, player: player, events: events, points: points, domain: domain, bucket: bucket)
                }
                // The brackets sit right on the track, their sides running on through it.
                VStack(alignment: .leading, spacing: 0) {
                    HistoryCompareLaneSlot(scrubber: scrubber, domain: domain)
                    HistoryRailTrack(scrubber: scrubber, recorder: recorder, points: points, gaps: gaps, domain: domain, bucket: bucket)
                }
                HistoryRailLabels(domain: domain)
            }
            HistoryTimelineControls(scrubber: scrubber, player: player, store: store, recorder: recorder, bucket: bucket)
        }
    }
}

/// The rail's track, the whole card's and the strip's: recorded time and
/// gaps (`HistoryCoverage`), A and B while comparing, and the moments shown.
/// Hovering previews a moment or names a gap; a click or drag moves
/// playback or pins a moment, a Shift-drag marks a session, and while
/// comparing a drag picks A or B. `compact` marks the moments with slim
/// ticks rather than pills, for the strip, whose caption names them.
struct HistoryRailTrack: View {
    let scrubber: HistoryScrubber
    /// The live recording, where a Shift-drag marks a session; nil for a file.
    let recorder: FlightRecorder?
    let points: [HistoryPoint]
    let gaps: [HistoryGap]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    var height: CGFloat = 22
    var compact = false

    /// What a drag along the track does, decided as it starts.
    private enum Drag {
        case pinning
        /// Moving the playhead, while there's playback.
        case seeking
        /// Marking a session from this moment, for a Shift-drag.
        case marking(Date)
        /// Picking A or B from this moment, while comparing.
        case comparing(Date)
    }

    @State private var drag: Drag?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HistoryCompareTrackBands(scrubber: scrubber, domain: domain, width: width)
                HistoryCoverage(points: points, gaps: gaps, domain: domain, bucket: bucket, width: width)
                HistoryRailGapOutline(scrubber: scrubber, domain: domain, width: width)
                if compact {
                    HistoryRailTicks(scrubber: scrubber, domain: domain, width: width, height: height)
                } else {
                    HistoryRailHandle(scrubber: scrubber, domain: domain, bucket: bucket, width: width)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover(at: location.x, width: width)
                case .ended: scrubber.hover(nil)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragged(from: value.startLocation.x, to: value.location.x, width: width) }
                .onEnded { _ in ended() })
        }
        .frame(height: height)
        .help("Click or drag along the timeline to move playback, or to pin a moment when there's none. "
            + (recorder == nil ? "" : "Shift-drag along the timeline to mark a session. ")
            + "While comparing, drag along it to pick A or B. Hover a hatched gap to see when nothing was recorded.")
    }

    /// After a drag that picked A, the next one picks B.
    private func ended() {
        if case .comparing = drag, scrubber.compare?.picking == .a, scrubber.compare?.a != nil {
            scrubber.compare?.picking = .b
        }
        drag = nil
    }

    /// Previews the moment under the pointer, or names the gap it's over
    /// (one under 8 points wide counts as that wide).
    private func hover(at x: CGFloat, width: CGFloat) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let time = HistoryMoment.time(at: x, width: width, domain: domain)
        if let gap = HistoryGap.gap(at: time, in: gaps, minimumSpan: 8 * span / Double(max(width, 1))) {
            scrubber.hover(nil, gap: gap)
        } else {
            scrubber.hover(moment(at: x, width: width))
        }
    }

    private func dragged(from start: CGFloat, to end: CGFloat, width: CGFloat) {
        guard let time = moment(at: end, width: width) else { return }
        if drag == nil {
            if scrubber.compare != nil, let from = moment(at: start, width: width) {
                drag = .comparing(from)
            } else {
                let from = recorder != nil && NSEvent.modifierFlags.contains(.shift) ? moment(at: start, width: width) : nil
                drag = from.map(Drag.marking) ?? (scrubber.playhead != nil ? .seeking : .pinning)
            }
        }
        switch drag {
        case .comparing(let from):
            let stretch = HistoryCompareDraft.stretch(from: from, to: time, bucket: bucket)
            switch scrubber.compare?.picking {
            case .a: if scrubber.compare?.a != stretch { scrubber.compare?.a = stretch }
            case .b: if scrubber.compare?.b != stretch { scrubber.compare?.b = stretch }
            case nil: break
            }
        case .marking(let from):
            scrubber.session = nil
            scrubber.draft = HistorySessionDraft(from: from, to: time == from ? nil : time, bucket: bucket)
        case .seeking:
            // The panel follows playback to where it's moved.
            scrubber.pin(nil)
            if scrubber.playhead != time { scrubber.playhead = time }
        case .pinning, nil:
            scrubber.pin(time)
        }
    }

    private func moment(at x: CGFloat, width: CGFloat) -> Date? {
        HistoryMoment.at(x: x, width: width, domain: domain, points: points)
    }
}

/// The rail's key, always over it: a sample of each thing the track and the
/// lanes draw, as they draw it, and its name. Recorded time, gaps and
/// events always; saved sessions while the range has any. Where there's
/// room, it ends with a word that hovering tells more.
private struct HistoryRailKey: View {
    /// Whether the event lane has markers.
    let hasEvents: Bool
    /// Whether the session lane has brackets.
    let hasSessions: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(hint: true)
            row(hint: false)
        }
        .font(.callout)
        .foregroundStyle(.secondaryText)
    }

    private func row(hint: Bool) -> some View {
        HStack(spacing: 14) {
            item("Recorded", help: "Stretches with records, in colour along the track") {
                Canvas { context, size in
                    HistoryCoverage.drawRecorded(CGRect(x: 0, y: (size.height - HistoryCoverage.bar) / 2, width: size.width,
                                                        height: HistoryCoverage.bar), in: context)
                }
                .frame(width: 18, height: 12)
            }
            item("Not recorded", help: "Gaps, hatched between dashed edges: the app wasn't running, the Mac slept, or updates were "
                + "paused. Every figure leaves them out; hover one on the track for when it was.") {
                Canvas { context, size in
                    HistoryCoverage.drawGaps([CGRect(x: 0.5, y: (size.height - HistoryCoverage.band) / 2, width: size.width - 1,
                                                     height: HistoryCoverage.band)], in: context, dark: colorScheme == .dark)
                }
                .frame(width: 18, height: 12)
            }
            item(hasEvents ? "Events" : "No events", help: hasEvents
                ? "Apps launched and quit, busy background processes, network changes, sleep and wake, in the lane over the "
                    + "track. Hover a marker for what happened; click it to move playback there."
                : "Nothing happened in this range that History notes: apps launching and quitting, busy background processes, "
                    + "network changes, sleep and wake.") {
                HistoryEventMarker(symbol: HistoryEventStyle.symbol(.appLaunched), count: 1, picked: false)
                    .opacity(hasEvents ? 1 : 0.45)
            }
            if hasSessions {
                item("Session", help: "Saved sessions, bracketed over the track; click one to pick it") {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(HistorySessionStyle.tint.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(HistorySessionStyle.tint.opacity(0.6)))
                        .frame(width: 18, height: 11)
                }
            }
            if hint {
                Spacer(minLength: 0)
                Text("Hover the timeline for details").fixedSize()
            }
        }
    }

    private func item(_ name: String, help: String, @ViewBuilder sample: () -> some View) -> some View {
        HStack(spacing: 5) {
            sample()
            Text(name).fixedSize()
        }
        .help(help)
    }
}

/// Times under the rail's track, each over a short tick: the start, middle
/// and end of the range, and the quarters too when there's room. They sit
/// at the same places as the plots' times, so they read for the charts too.
private struct HistoryRailLabels: View {
    let domain: ClosedRange<Date>

    var body: some View {
        // A geometry reader takes the width it's offered, whatever the labels
        // measure, so they can never widen the rail past the charts.
        GeometryReader { geometry in
            let track = geometry.size.width
            let style = HistoryMoment.railStyle(for: domain)
            let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
            let fractions: [CGFloat] = track >= 560 ? [0, 0.25, 0.5, 0.75, 1] : [0, 0.5, 1]
            ZStack(alignment: .topLeading) {
                // Holds the track's left edge, which the labels are placed from.
                Color.clear.frame(width: track, height: 1)
                ForEach(fractions, id: \.self) { fraction in
                    // The ends keep inside the track; the rest centre on their tick.
                    let anchor: CGFloat = fraction == 0 ? 0 : fraction == 1 ? 1 : 0.5
                    VStack(alignment: anchor == 0 ? .leading : anchor == 1 ? .trailing : .center, spacing: 1) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1, height: 3)
                        Text(domain.lowerBound.addingTimeInterval(span * fraction).formatted(style))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondaryText)
                            .fixedSize()
                    }
                    .alignmentGuide(.leading) { size in -(track * fraction - size.width * anchor) }
                }
            }
        }
        .frame(height: 17)
        .accessibilityElement(children: .combine)
    }
}

/// Saved sessions within the range, as brackets over the track, and the
/// one being marked, dashed. A click on a bracket picks its session (and
/// shades it on the charts), again lets it go. Takes no room while the
/// range has none.
private struct HistorySessionLane: View {
    let scrubber: HistoryScrubber
    let store: HistoryRecordingStore
    let domain: ClosedRange<Date>

    var body: some View {
        let sessions = store.sessions.filter { $0.end >= domain.lowerBound && $0.start <= domain.upperBound }
        let draft = scrubber.draft
        if !sessions.isEmpty || draft != nil {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    // Holds the lane's left edge, which the brackets are placed from.
                    Color.clear.frame(width: width, height: 1)
                    ForEach(sessions) { session in
                        bracket(session, width: width)
                    }
                    if let draft {
                        marking(draft, width: width)
                    }
                }
                .frame(width: width, height: geometry.size.height, alignment: .leading)
            }
            .frame(height: 18)
        }
    }

    private func bracket(_ session: RecordingSession, width: CGFloat) -> some View {
        let picked = scrubber.session?.id == session.id
        let (start, length) = place(session.start, session.end, width: width)
        let tint = HistorySessionStyle.tint
        return Button {
            scrubber.draft = nil
            scrubber.session = picked ? nil : session
        } label: {
            Text(length >= 40 ? HistorySessionStyle.title(session) : "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(picked ? Color.primary : Color.primary.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(width: length, height: 16, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(picked ? 0.32 : 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(picked ? 0.9 : 0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(HistorySessionStyle.title(session)), \(HistorySessionStyle.span(session.start, session.end)). "
            + (picked ? "Click to let it go." : "Click to pick it, to export or play it back."))
        .alignmentGuide(.leading) { _ in -start }
    }

    @ViewBuilder private func marking(_ draft: HistorySessionDraft, width: CGFloat) -> some View {
        let tint = HistorySessionStyle.tint
        if let end = draft.end {
            let (start, length) = place(draft.start, end, width: width)
            Text(length >= 80 ? "New session" : "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(width: length, height: 16, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .alignmentGuide(.leading) { _ in -start }
        } else if domain.contains(draft.start) {
            let x = HistoryMoment.x(of: draft.start, width: width, domain: domain)
            HStack(spacing: 3) {
                Rectangle().fill(tint).frame(width: 2, height: 16)
                Text("Start").font(.system(size: 11, weight: .semibold)).fixedSize()
            }
            .alignmentGuide(.leading) { _ in -min(x - 1, width - 34) }
        }
    }

    /// Where a stretch starts along the lane and how long it is, cut to the range.
    private func place(_ start: Date, _ end: Date, width: CGFloat) -> (CGFloat, CGFloat) {
        let lower = HistoryMoment.x(of: max(start, domain.lowerBound), width: width, domain: domain)
        let upper = HistoryMoment.x(of: min(end, domain.upperBound), width: width, domain: domain)
        let length = max(upper - lower, 6)
        return (min(lower, width - length), length)
    }
}

/// The rail's track: recorded stretches in colour, and each gap (the app
/// wasn't running, the Mac slept) hatched between dashed edges, at least a
/// couple of points wide, so even a short one shows and can be hovered. One
/// canvas, drawn again only on a load or a resize.
struct HistoryCoverage: View {
    let points: [HistoryPoint]
    let gaps: [HistoryGap]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// The recorded bar's height, and a gap's hatched band's.
    static let bar: CGFloat = 8
    static let band: CGFloat = 12

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { context, size in
            let middle = size.height / 2
            context.fill(Path(roundedRect: CGRect(x: 0, y: middle - Self.bar / 2, width: size.width, height: Self.bar), cornerRadius: Self.bar / 2),
                         with: .color(Color.primary.opacity(0.09)))
            Self.drawGaps(gaps.map { gap in
                let start = x(gap.start)
                return CGRect(x: start, y: middle - Self.band / 2, width: max(x(gap.end), start + 2) - start, height: Self.band)
            }, in: context, dark: dark)
            for stretch in stretches {
                let start = x(stretch.lowerBound)
                Self.drawRecorded(CGRect(x: start, y: middle - Self.bar / 2, width: max(x(stretch.upperBound) - start, 3), height: Self.bar),
                                  in: context)
            }
        }
        .frame(width: width)
        .accessibilityLabel(gaps.isEmpty ? "Recorded throughout" : "\(gaps.count) gaps not recorded")
    }

    /// A recorded stretch: a bar in the accent colour.
    static func drawRecorded(_ rect: CGRect, in context: GraphicsContext) {
        let fill = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.5)]),
            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: fill)
    }

    /// Gaps: each band washed and hatched between dashed edges, as the track
    /// and the rail's key draw them.
    static func drawGaps(_ bands: [CGRect], in context: GraphicsContext, dark: Bool) {
        guard let first = bands.first else { return }
        let ink = Color(nsColor: .labelColor)
        var clip = Path()
        var edges = Path()
        var reach = first
        for band in bands {
            clip.addRect(band)
            reach = reach.union(band)
            for edge in [band.minX, band.maxX] {
                edges.move(to: CGPoint(x: edge, y: band.minY))
                edges.addLine(to: CGPoint(x: edge, y: band.maxY))
            }
        }
        context.fill(clip, with: .color(HistoryGapStyle.wash(dark: dark)))
        var lines = context
        lines.clip(to: clip)
        var hatch = Path()
        var position = reach.minX - reach.height
        while position < reach.maxX + 4 {
            hatch.move(to: CGPoint(x: position, y: reach.maxY))
            hatch.addLine(to: CGPoint(x: position + reach.height, y: reach.minY))
            position += 4
        }
        lines.stroke(hatch, with: .color(ink.opacity(dark ? 0.32 : 0.26)), lineWidth: 1)
        context.stroke(edges, with: .color(ink.opacity(dark ? 0.5 : 0.42)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }

    private func x(_ time: Date) -> CGFloat {
        HistoryMoment.x(of: min(max(time, domain.lowerBound), domain.upperBound), width: width, domain: domain)
    }

    /// Each unbroken run of points, from the start of its first bucket to its last point.
    private var stretches: [ClosedRange<Date>] {
        var runs: [ClosedRange<Date>] = []
        var current: (segment: Int, range: ClosedRange<Date>)?
        for point in points {
            if let run = current, run.segment == point.segment {
                current = (run.segment, run.range.lowerBound...point.time)
            } else {
                if let run = current { runs.append(run.range) }
                let start = min(max(point.time.addingTimeInterval(-bucket), domain.lowerBound), point.time)
                current = (point.segment, start...point.time)
            }
        }
        if let run = current { runs.append(run.range) }
        return runs
    }
}

/// An outline round the gap under the pointer, or else the one picked from
/// the gaps menu, so it stands out from the rest.
private struct HistoryRailGapOutline: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>
    let width: CGFloat

    var body: some View {
        if let gap = scrubber.hoveredGap ?? scrubber.selectedGap, gap.end >= domain.lowerBound, gap.start <= domain.upperBound {
            let start = HistoryMoment.x(of: max(gap.start, domain.lowerBound), width: width, domain: domain)
            let end = max(HistoryMoment.x(of: min(gap.end, domain.upperBound), width: width, domain: domain), start + 2)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                .frame(width: end - start + 6, height: 16)
                .alignmentGuide(.leading) { _ in -(start - 3) }
                .allowsHitTesting(false)
        }
    }
}

/// The rail's handle: a pill for each moment shown, each its own look. Where
/// playback is, in the replay's tint, "Playing" or "Paused"; a pinned moment
/// in the accent colour; a moment the pointer previews, outlined and dashed
/// like its line on the charts, "Preview"; and "Latest" (a file's "End") at
/// the right end while nothing is pinned or played. Over a gap, a tag with
/// what wasn't recorded takes the preview's place.
private struct HistoryRailHandle: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    let width: CGFloat

    private var plain: Color { Color(nsColor: .controlBackgroundColor) }

    var body: some View {
        let pinned = scrubber.pinned.flatMap { domain.contains($0) ? $0 : nil }
        let playhead = scrubber.playhead.flatMap { domain.contains($0) ? $0 : nil }
        if pinned == nil, playhead == nil {
            pill(Text(scrubber.endName), at: width, fill: plain, text: Color.accentColor, border: Color.accentColor.opacity(0.7))
        }
        if let playhead {
            let playing = scrubber.isPlaying
            let label = HistoryMoment.label(playhead, bucket: bucket)
            pill(Text("\(Image(systemName: playing ? "play.fill" : "pause.fill")) \(playing ? "Playing" : "Paused") \(label)"),
                 at: x(of: playhead), fill: HistorySessionStyle.tint, text: Color.white)
        }
        if let pinned {
            pill(Text("\(Image(systemName: "pin.fill")) \(HistoryMoment.label(pinned, bucket: bucket))"),
                 at: x(of: pinned), fill: Color.accentColor, text: Color.white)
        }
        if let hovered = scrubber.hovered, hovered != pinned, hovered != playhead, domain.contains(hovered) {
            pill(Text("Preview \(HistoryMoment.label(hovered, bucket: bucket))"), at: x(of: hovered),
                 fill: plain, text: Color.primary, border: Color.primary.opacity(0.45), dashed: true)
        } else if let gap = scrubber.hoveredGap {
            let middle = min(max(gap.start.addingTimeInterval(gap.duration / 2), domain.lowerBound), domain.upperBound)
            pill(Text("Not recorded · \(HistoryGapStyle.describe(gap))"), at: x(of: middle),
                 fill: plain, text: .secondaryText, border: Color.primary.opacity(0.35), dashed: true)
        }
    }

    private func x(of time: Date) -> CGFloat {
        HistoryMoment.x(of: time, width: width, domain: domain)
    }

    /// A pill centred on `x`, kept within the track.
    private func pill(_ label: Text, at x: CGFloat, fill: Color, text: some ShapeStyle, border: Color = .clear,
                      dashed: Bool = false) -> some View {
        label
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
            .fixedSize()
            .alignmentGuide(.leading) { size in -min(max(x - size.width / 2, 0), width - size.width) }
    }
}

/// The strip's moments on its slim track: a tick where playback is, in the
/// replay's tint, one at a pinned moment in the accent colour, a dashed one
/// at a moment the pointer previews, and one at the right end while nothing
/// is pinned or played. The strip's caption says what each is.
private struct HistoryRailTicks: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let pinned = scrubber.pinned.flatMap { domain.contains($0) ? $0 : nil }
        let playhead = scrubber.playhead.flatMap { domain.contains($0) ? $0 : nil }
        if pinned == nil, playhead == nil {
            tick(at: width, tint: Color.accentColor)
        }
        if let playhead {
            tick(at: x(of: playhead), tint: HistorySessionStyle.tint)
        }
        if let pinned {
            tick(at: x(of: pinned), tint: Color.accentColor)
        }
        if let hovered = scrubber.hovered, hovered != pinned, hovered != playhead, domain.contains(hovered) {
            let place = min(max(x(of: hovered) - 0.75, 0), width - 1.5)
            Rectangle()
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: 1.5, height: height + 2)
                .alignmentGuide(.leading) { _ in -place }
                .allowsHitTesting(false)
        }
    }

    private func x(of time: Date) -> CGFloat {
        HistoryMoment.x(of: time, width: width, domain: domain)
    }

    /// A tick centred on `x`, kept within the track, with a light edge so it
    /// reads over the recorded bar.
    private func tick(at x: CGFloat, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(tint)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 0.5))
            .frame(width: 4, height: height + 2)
            .alignmentGuide(.leading) { _ in -min(max(x - 2, 0), width - 4) }
            .allowsHitTesting(false)
    }
}
