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
/// range were recorded, and its handle carries the pinned moment's time
/// (or sits at the right end, "Latest"), with times along it below. Clicking
/// or dragging along it pins a moment, like the charts, hovering previews
/// one, and a Shift-drag marks a session. Saved sessions ride above the
/// track, and the controls to mark, export and play back sit under it.
///
/// The track spans the same width as the charts' plots, so the handle sits
/// over their markers. Only its handle, the sessions above it and the
/// controls read the scrubber, so none of this redraws the charts.
struct HistoryRail: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let store: HistoryRecordingStore
    /// The live recording, where sessions are saved; nil for a recording
    /// file, which is read-only.
    let recorder: FlightRecorder?
    let points: [HistoryPoint]
    let domain: ClosedRange<Date>
    /// Seconds each point averages.
    let bucket: TimeInterval

    /// What a drag along the track does, decided as it starts.
    private enum Drag {
        case pinning
        /// Marking a session from this moment, for a Shift-drag.
        case marking(Date)
    }

    @State private var drag: Drag?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                if recorder != nil {
                    HistorySessionLane(scrubber: scrubber, store: store, domain: domain)
                }
                track
                HistoryRailLabels(domain: domain)
            }
            HistoryTimelineControls(scrubber: scrubber, player: player, store: store, recorder: recorder, bucket: bucket)
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HistoryCoverage(points: points, domain: domain, bucket: bucket, width: width)
                HistoryRailHandle(scrubber: scrubber, domain: domain, bucket: bucket, width: width)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): scrubber.hovered = moment(at: location.x, width: width)
                case .ended: scrubber.hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragged(from: value.startLocation.x, to: value.location.x, width: width) }
                .onEnded { _ in drag = nil })
        }
        .frame(height: 22)
        .help(recorder == nil ? "Click or drag along the timeline or a graph to pin a moment"
            : "Click or drag along the timeline or a graph to pin a moment. Shift-drag along the timeline to mark a session.")
    }

    private func dragged(from start: CGFloat, to end: CGFloat, width: CGFloat) {
        guard let time = moment(at: end, width: width) else { return }
        if drag == nil {
            let from = recorder != nil && NSEvent.modifierFlags.contains(.shift) ? moment(at: start, width: width) : nil
            drag = from.map(Drag.marking) ?? .pinning
        }
        switch drag {
        case .marking(let from):
            scrubber.session = nil
            scrubber.draft = HistorySessionDraft(from: from, to: time == from ? nil : time, bucket: bucket)
        case .pinning, nil:
            scrubber.pinned = time
        }
    }

    private func moment(at x: CGFloat, width: CGFloat) -> Date? {
        HistoryMoment.at(x: x, width: width, domain: domain, points: points)
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
                            .font(.system(size: 10.5).monospacedDigit())
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
                .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 10, weight: .semibold))
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
                Text("Start").font(.system(size: 10, weight: .semibold)).fixedSize()
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

/// The rail's track: recorded stretches in colour, bare track where nothing
/// was recorded (the app wasn't running, or the Mac slept).
private struct HistoryCoverage: View {
    let points: [HistoryPoint]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.09))
                .frame(width: width, height: 6)
            ForEach(stretches, id: \.lowerBound) { stretch in
                let start = HistoryMoment.x(of: stretch.lowerBound, width: width, domain: domain)
                let end = HistoryMoment.x(of: stretch.upperBound, width: width, domain: domain)
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: max(end - start, 3), height: 6)
                    .alignmentGuide(.leading) { _ in -start }
            }
        }
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

/// The rail's handle, a pill with the pinned moment's time or "Latest" at
/// the right end, and a thin line where the pointer previews a moment.
private struct HistoryRailHandle: View {
    let scrubber: HistoryScrubber
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    let width: CGFloat

    var body: some View {
        if let hovered = scrubber.hovered, hovered != scrubber.pinned, domain.contains(hovered) {
            let x = HistoryMoment.x(of: hovered, width: width, domain: domain)
            Capsule()
                .fill(Color.primary.opacity(0.5))
                .frame(width: 2, height: 18)
                .alignmentGuide(.leading) { _ in -(x - 1) }
        }
        if let pinned = scrubber.pinned, domain.contains(pinned) {
            pill(HistoryMoment.label(pinned, bucket: bucket), at: HistoryMoment.x(of: pinned, width: width, domain: domain), pinned: true)
        } else {
            pill("Latest", at: width, pinned: false)
        }
    }

    /// A pill centred on `x`, kept within the track.
    private func pill(_ text: String, at x: CGFloat, pinned: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(pinned ? Color.white : Color.accentColor)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(pinned ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(pinned ? 0 : 0.7)))
            .fixedSize()
            .alignmentGuide(.leading) { size in -min(max(x - size.width / 2, 0), width - size.width) }
    }
}
