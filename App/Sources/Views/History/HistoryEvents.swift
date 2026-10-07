import OTMKit
import SwiftUI

/// How the History page draws and words its events (`HistoryEvent`).
enum HistoryEventStyle {
    static func symbol(_ kind: HistoryEvent.Kind) -> String {
        switch kind {
        case .appLaunched: "arrow.up.square.fill"
        case .appQuit: "xmark.square.fill"
        case .processStarted: "gearshape.fill"
        case .processExited: "gearshape"
        case .networkChanged: "network"
        case .sleep: "moon.zzz.fill"
        case .wake: "sun.max.fill"
        }
    }

    /// "Xcode launched", "5 × clang started", "Network: Wi-Fi (en0)".
    static func title(_ event: HistoryEvent) -> String {
        let name = event.count > 1 ? "\(event.count) × \(event.name)" : event.name
        return switch event.kind {
        case .appLaunched: "\(name) launched"
        case .appQuit: "\(name) quit"
        case .processStarted: "\(name) started"
        case .processExited: "\(name) exited"
        case .networkChanged: event.name.isEmpty ? "Network disconnected" : "Network: \(event.name)"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke"
        }
    }

    /// What there is to say beyond the title: a network's new address, and
    /// for a background process, that it was busy.
    static func detail(_ event: HistoryEvent) -> String? {
        switch event.kind {
        case .networkChanged: event.detail.isEmpty ? nil : event.detail
        case .processStarted: "A background process that used at least \(Int(ProcessEventTracker.busyPercent))% of a core"
        case .processExited: "A background process that had been busy"
        case .appLaunched, .appQuit, .sleep, .wake: nil
        }
    }

    /// Why a time is approximate, for tooltips.
    static let approximateNote = "Its time is approximate: it was found by comparing one update's process list with the next, "
        + "so it's only known to within an update."

    /// "10:12:06 AM", or "about 10:12:06 AM" for an approximate time.
    static func time(_ event: HistoryEvent) -> String {
        let time = event.time.formatted(.dateTime.hour().minute().second())
        return event.isApproximate ? "about \(time)" : time
    }

    /// A tooltip for several events at one place on the timeline.
    static func summary(_ events: [HistoryEvent]) -> String {
        var lines = events.prefix(8).map { "\(time($0))  \(title($0))" }
        if events.count > 8 { lines.append("and \(events.count - 8) more") }
        if events.contains(where: \.isApproximate) { lines.append(approximateNote) }
        lines.append(events.count == 1 ? "Click to move playback here." : "Click to move playback to the first.")
        return lines.joined(separator: "\n")
    }

    /// "2 app launches, 1 network change", or "none".
    static func counts(_ counts: [(kind: HistoryEvent.Kind, count: Int)]) -> String {
        let parts = counts.filter { $0.count > 0 }.map { kind, count in
            let noun = switch kind {
            case .appLaunched: count == 1 ? "app launch" : "app launches"
            case .appQuit: count == 1 ? "app quit" : "apps quit"
            case .processStarted: count == 1 ? "process started" : "processes started"
            case .processExited: count == 1 ? "process exited" : "processes exited"
            case .networkChanged: count == 1 ? "network change" : "network changes"
            case .sleep: count == 1 ? "sleep" : "sleeps"
            case .wake: count == 1 ? "wake" : "wakes"
            }
            return "\(count) \(noun)"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// Moves playback to `event`: pauses it, puts the playhead on the
    /// point whose stretch holds the event, and marks the event picked.
    @MainActor
    static func select(_ event: HistoryEvent, scrubber: HistoryScrubber, player: HistoryPlayer, points: [HistoryPoint],
                       bucket: TimeInterval) {
        player.pause()
        scrubber.pin(nil)
        let time = HistoryPoint.covering(event.time, in: points, bucket: bucket)?.time ?? event.time
        if scrubber.playhead != time { scrubber.playhead = time }
        scrubber.selectedEvent = event
    }
}

/// The events within the range as markers over the rail's track: one
/// symbol per kind, those too close to draw apart as one marker with a
/// count. Hovering one previews its moment and lists what happened in the
/// tooltip; clicking moves playback there. Takes no room while the range
/// has none.
struct HistoryEventLane: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let events: [HistoryEvent]
    let points: [HistoryPoint]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval

    private static let size: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
            let clusters = HistoryEvent.clusters(events.filter { domain.contains($0.time) },
                                                 spacing: Double(Self.size + 3) * span / Double(max(width, 1)))
            ZStack(alignment: .leading) {
                // Holds the lane's left edge, which the markers are placed from.
                Color.clear.frame(width: width, height: 1)
                ForEach(clusters, id: \.first?.id) { cluster in
                    marker(cluster, width: width)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Self.size + 1)
    }

    private func marker(_ cluster: [HistoryEvent], width: CGFloat) -> some View {
        let first = cluster[0]
        let picked = scrubber.selectedEvent.map { picked in cluster.contains(picked) } ?? false
        let x = HistoryMoment.x(of: first.time, width: width, domain: domain)
        let count = cluster.reduce(0) { $0 + $1.count }
        let kinds = Set(cluster.map(\.kind))
        return Button {
            HistoryEventStyle.select(first, scrubber: scrubber, player: player, points: points, bucket: bucket)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: kinds.count == 1 ? HistoryEventStyle.symbol(first.kind) : "square.stack.fill")
                    .font(.system(size: 9, weight: .bold))
                if count > 1 {
                    Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, count > 1 ? 4 : 0)
            .frame(minWidth: Self.size, minHeight: Self.size)
            .background(Capsule().fill(picked ? Color.accentColor : Color(nsColor: .labelColor).opacity(0.62)))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            scrubber.hover(inside ? HistoryPoint.covering(first.time, in: points, bucket: bucket)?.time : nil)
        }
        .help(HistoryEventStyle.summary(cluster))
        .accessibilityLabel(cluster.map(HistoryEventStyle.title).joined(separator: ", "))
        .alignmentGuide(.leading) { size in -min(max(x - size.width / 2, 0), width - size.width) }
    }
}

/// The range's events, counted after the coverage line, each a click
/// away: picking one moves playback to it. The latest are listed when
/// there are many.
struct HistoryEventsMenu: View {
    let events: [HistoryEvent]
    let points: [HistoryPoint]
    let bucket: TimeInterval
    let scrubber: HistoryScrubber
    let player: HistoryPlayer

    private static let listed = 30

    var body: some View {
        let shown = events.suffix(Self.listed)
        Menu {
            Section("Events") {
                ForEach(Array(shown)) { event in
                    Button {
                        HistoryEventStyle.select(event, scrubber: scrubber, player: player, points: points, bucket: bucket)
                    } label: {
                        Label("\(HistoryEventStyle.time(event))  \(HistoryEventStyle.title(event))",
                              systemImage: HistoryEventStyle.symbol(event.kind))
                    }
                }
            }
            if events.count > shown.count {
                Text("\(events.count - shown.count) earlier events not listed")
            }
        } label: {
            Text(events.count == 1 ? "1 event" : "\(events.count) events")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // As the gaps menu: the dots either side sit evenly.
        .padding(.horizontal, -2)
        .help("What happened while recording: apps launched and quit, busy background processes started and exited, "
            + "network changes, sleep and wake. They're marked over the timeline; pick one to move playback to it.")
    }
}

/// The events near the moment the panel shows, with how long before or
/// after it each happened.
struct HistoryMomentEvents: View {
    let events: [HistoryEvent]
    let time: Date
    /// Seconds the moment's figures average.
    let bucket: TimeInterval
    let selected: HistoryEvent?

    private static let shown = 5

    /// How far either side counts as near: a minute, or two points where they're coarser.
    private var reach: TimeInterval { max(60, bucket * 2) }

    var body: some View {
        let near = HistoryEvent.near(time, in: events, before: reach, after: reach)
        // The closest first, then put back in order.
        let closest = near.sorted { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
            .prefix(Self.shown).sorted { $0.time < $1.time }
        VStack(alignment: .leading, spacing: 5) {
            Text("Events near this moment").font(.headline)
            if closest.isEmpty {
                Text("None within \(Format.roughDuration(reach)) either side.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
            }
            ForEach(closest) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: HistoryEventStyle.symbol(event.kind))
                        .foregroundStyle(event == selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondaryText))
                        .frame(width: 16)
                    Text(HistoryEventStyle.title(event))
                        .fontWeight(event == selected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(offset(event))
                        .foregroundStyle(.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.tableText)
                .help(tooltip(event))
            }
            if near.count > closest.count {
                Text("\(near.count - closest.count) more within \(Format.roughDuration(reach))")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    /// "12 s before", "during these 10 s", "about 5 s after".
    private func offset(_ event: HistoryEvent) -> String {
        let seconds = event.time.timeIntervalSince(time)
        let text: String
        if seconds <= 0, seconds > -bucket {
            text = "during these \(Format.timeSpan(bucket))"
        } else {
            text = "\(Format.timeSpan(abs(seconds).rounded())) \(seconds < 0 ? "before" : "after")"
        }
        return event.isApproximate ? "about " + text : text
    }

    private func tooltip(_ event: HistoryEvent) -> String {
        [HistoryEventStyle.time(event) + "  " + HistoryEventStyle.title(event), HistoryEventStyle.detail(event),
         event.isApproximate ? HistoryEventStyle.approximateNote : nil].compactMap { $0 }.joined(separator: "\n")
    }
}
