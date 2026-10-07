import AppKit
import OTMKit
import SwiftUI

/// Follows the History page's scrolling, from its clip view's bounds, to
/// fold the pinned timeline card to a strip once the charts' top has
/// scrolled out of view (`RailFold`), and to name the section at the top of
/// the page for the strip. The card's place, its heights and the sections'
/// frames are noted as the page lays out, never per tick; only the fold
/// and the section are observed, each set only when it changes, and only
/// the pinned rail reads them, so scrolling never redraws the charts.
@Observable
@MainActor
final class HistoryPageScroll {
    nonisolated static let space = "historyPage"
    /// The page's room between the header, the card and the charts.
    nonisolated static let spacing: CGFloat = 16

    private(set) var fold = RailFold()
    /// The section at the top of the page, under the strip; nil while it's not folded.
    private(set) var section: String?

    @ObservationIgnored weak var tracker: HistoryScrollTrackerView?
    /// Where the card sits unpinned, in the page's coordinates.
    @ObservationIgnored private var railTop = CGFloat.nan
    /// The whole card's height, as it was last shown, and the strip's.
    @ObservationIgnored private var wholeHeight = CGFloat.nan
    @ObservationIgnored private var stripHeight: CGFloat = 0
    @ObservationIgnored private var frames: [String: CGRect] = [:]

    /// The bottom of the page's header, which the card sits under.
    func setHeaderBottom(_ bottom: CGFloat) {
        railTop = bottom + Self.spacing
        follow()
    }

    /// The whole card's height, with its room above and below.
    func setWholeHeight(_ height: CGFloat) {
        wholeHeight = height
        follow()
    }

    /// The strip's height, with its room above and below.
    func setStripHeight(_ height: CGFloat) {
        stripHeight = height
        follow()
    }

    /// A section's frame in the page, or nil once it's gone.
    func setFrame(_ frame: CGRect?, of section: String) {
        guard frames[section] != frame else { return }
        frames[section] = frame
        follow()
    }

    /// The page scrolled.
    func scrolled() {
        follow()
    }

    /// The strip's expand control: the whole card until the page is back at the top.
    func open() {
        update { $0.open() }
    }

    /// Folds a card opened from the strip again.
    func foldAgain() {
        update { $0.fold() }
        follow()
    }

    private func update(_ change: (inout RailFold) -> Void) {
        var next = fold
        change(&next)
        if next != fold { fold = next }
    }

    private func follow() {
        guard let visible = tracker?.visiblePage else { return }
        let chartsTop = railTop + wholeHeight + Self.spacing
        update { $0.scrolled(visibleTop: Double(visible.minY), railTop: Double(railTop), chartsTop: Double(chartsTop)) }
        let next = fold.isFolded ? topSection(below: visible.minY + stripHeight) : nil
        if next != section { section = next }
    }

    /// The section showing just under the strip (`ScrollSpy`).
    private func topSection(below line: CGFloat) -> String? {
        let cards = frames.sorted { $0.value.minY < $1.value.minY }.map { ScrollSpy.Card($0.key, top: $0.value.minY, bottom: $0.value.maxY) }
        return ScrollSpy.current(cards, line: Double(line + 8))
    }
}

extension View {
    /// Notes where this section of the History page is, for the folded
    /// strip to name the one at the top. Measured as the page lays out;
    /// scrolling moves nothing in the page's own coordinates.
    func historySection(_ name: String, scroll: HistoryPageScroll) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HistoryPageScroll.space)) } action: { frame in
            scroll.setFrame(frame.height > 0 ? frame : nil, of: name)
        }
        .onDisappear { scroll.setFrame(nil, of: name) }
    }
}

/// Sits behind the History page's content to follow its scroll view: where
/// the visible part is, in the page's coordinates.
struct HistoryScrollTracker: NSViewRepresentable {
    let scroll: HistoryPageScroll

    func makeNSView(context: Context) -> HistoryScrollTrackerView {
        let view = HistoryScrollTrackerView()
        view.scroll = scroll
        scroll.tracker = view
        return view
    }

    func updateNSView(_ view: HistoryScrollTrackerView, context: Context) {
        view.scroll = scroll
        scroll.tracker = view
    }
}

final class HistoryScrollTrackerView: NSView {
    var scroll: HistoryPageScroll?
    private weak var clip: NSClipView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followScrolling()
    }

    override func layout() {
        super.layout()
        followScrolling()
    }

    /// Watches the page's clip view; only scrolling calls back.
    private func followScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== self.clip else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        self.clip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(pageScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        scroll?.scrolled()
    }

    @objc private func pageScrolled(_ notification: Notification) {
        scroll?.scrolled()
    }

    /// The part of the page in view, in the page's coordinates (this view
    /// spans the page), below any inset the window's toolbar takes.
    var visiblePage: CGRect? {
        guard let clip else { return nil }
        var rect = convert(clip.bounds, from: clip)
        let inset = clip.contentInsets.top
        rect.origin.y += inset
        rect.size.height -= inset
        return rect
    }
}

/// The timeline pinned over the charts: the whole card near the top of the
/// page (in a narrow window, with the moment's summary over it), and a
/// strip once the page has scrolled down among the charts. The one view
/// that reads the fold, so folding moves the charts but never redraws them.
struct HistoryPinnedRail: View {
    let scroll: HistoryPageScroll
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let store: HistoryRecordingStore
    /// The live recording, where sessions are marked; nil for a file.
    let recorder: FlightRecorder?
    /// What the summary reads: the opened file, else the live recording.
    let source: FlightRecorder?
    let points: [HistoryPoint]
    let gaps: [HistoryGap]
    let events: [HistoryEvent]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    /// Whether the moment panel rides over the rail, in a narrow window.
    let compact: Bool
    /// The span shown, as the strip names it: "Last hour", "41 min span".
    let span: String

    var body: some View {
        let state = scroll.fold.state
        if state == .folded {
            HistoryRailStrip(scroll: scroll, scrubber: scrubber, player: player, recorder: recorder, points: points, gaps: gaps,
                             spikes: events.filter { $0.kind == .spike }, domain: domain, bucket: bucket, span: span)
                .modifier(HistoryPinnedRoom())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.setStripHeight($0) }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if compact {
                    HistoryMomentSummary(scrubber: scrubber, player: player, points: points, bucket: bucket, recorder: source,
                                         events: events)
                }
                HistoryRail(scrubber: scrubber, player: player, store: store, recorder: recorder, points: points, gaps: gaps,
                            events: events, domain: domain, bucket: bucket, onFold: state == .opened ? { scroll.foldAgain() } : nil)
            }
            .modifier(HistoryPinnedRoom())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.setWholeHeight($0) }
        }
    }
}

/// The pinned rail's room above and below, on the page's background, which
/// covers the charts as they scroll under it.
private struct HistoryPinnedRoom: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(.background)
    }
}

/// The timeline folded to a strip while the page is scrolled down among
/// the charts: the section at the top, the span and the moment shown, Play
/// and the speed, a button for the whole card, and under them the track
/// itself, slimmer, which previews, pins, moves playback and picks A or B
/// as the card's does.
private struct HistoryRailStrip: View {
    let scroll: HistoryPageScroll
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let recorder: FlightRecorder?
    let points: [HistoryPoint]
    let gaps: [HistoryGap]
    /// Spike captures' events, the one kind the strip marks.
    let spikes: [HistoryEvent]
    let domain: ClosedRange<Date>
    let bucket: TimeInterval
    let span: String

    var body: some View {
        // A card's surface, with less room than a card's round its two rows.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HistoryRailStripCaption(scroll: scroll, scrubber: scrubber, span: span, latest: points.last?.time, bucket: bucket)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HistoryTransport(scrubber: scrubber, player: player)
                Button {
                    scroll.open()
                } label: {
                    Label("Show Whole Timeline", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .fixedSize()
                .help("Show the whole timeline, with its key, lanes and controls, until the page is back at the top")
            }
            .controlSize(.small)
            HistoryRailTrack(scrubber: scrubber, recorder: recorder, points: points, gaps: gaps, domain: domain, bucket: bucket,
                             height: 14, compact: true)
                .overlay { HistorySpikeStripMarks(spikes: spikes, domain: domain) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tinted while comparing, as the card is.
        .background(CardSurface(tint: scrubber.comparing ? HistoryCompareDraft.tintA : nil, glow: 0))
    }
}

/// The strip's caption: the section at the top of the page, the span shown
/// and the moment the panel shows, dropping the span and then the section
/// as the strip narrows. A view of its own, as it reads the scrubber.
private struct HistoryRailStripCaption: View {
    let scroll: HistoryPageScroll
    let scrubber: HistoryScrubber
    let span: String
    /// The last point, the moment shown while nothing is picked.
    let latest: Date?
    let bucket: TimeInterval

    var body: some View {
        let section = scroll.section
        ViewThatFits(in: .horizontal) {
            line(section: section, span: span)
            line(section: section, span: nil)
            moment.lineLimit(1)
        }
        .font(.callout)
        .help("The section at the top of the page, the span the charts show and the moment the panel shows. "
            + "Scroll back to the top, or use the button at the end, for the whole timeline.")
    }

    private func line(section: String?, span: String?) -> some View {
        HStack(spacing: 5) {
            if let section {
                Text(section).fontWeight(.semibold)
                separator
            }
            if let span {
                Text(span).foregroundStyle(.secondaryText)
                separator
            }
            moment
        }
        .fixedSize()
    }

    private var separator: some View {
        Text("·").foregroundStyle(.secondaryText)
    }

    /// The moment shown, as the rail's handle names it.
    @ViewBuilder private var moment: some View {
        switch scrubber.focus {
        case .preview(let time):
            Text("Preview \(HistoryMoment.label(time, bucket: bucket))")
                .foregroundStyle(Color.primary)
        case .pinned(let time):
            Text("\(Image(systemName: "pin.fill")) \(HistoryMoment.label(time, bucket: bucket))")
                .foregroundStyle(Color.accentColor)
        case .playback(let time, let playing):
            let label = HistoryMoment.label(time, bucket: bucket)
            Text("\(Image(systemName: playing ? "play.fill" : "pause.fill")) \(playing ? "Playing" : "Paused") \(label)")
                .foregroundStyle(HistorySessionStyle.tint)
        case .end:
            Text(latest.map { "\(scrubber.endName) \(HistoryMoment.label($0, bucket: bucket))" } ?? scrubber.endName)
                .foregroundStyle(.secondaryText)
        }
    }
}
