import AppKit
import OTMKit
import SwiftUI

/// What the System page can scroll to: its summary, each card by kind
/// (the same across reads, refreshes and searches) and each card's rows.
enum SystemTarget: Hashable {
    case overview
    case card(InfoSection.Kind)
    case row(InfoSection.Kind, Int)

    /// The card a search match is in, or the summary.
    init(cardOf match: SystemReportSearch.Match) {
        self = match.kind.map { .card($0) } ?? .overview
    }
}

/// The System page's place and its jumps. It notes where each card was laid
/// out and which group of cards is at the top as the page scrolls, for the
/// jump bar; jumps to a group or a search's match through the page's
/// `ScrollViewReader` and marks the match for a moment; and while Refresh
/// reads the page again, keeps the card at the top where it was. Only the
/// group at the top, the match and the mark are observed, so scrolling
/// redraws the jump bar only when the group changes, and nothing here runs
/// per tick.
@Observable
@MainActor
final class SystemNavigator {
    /// The page's coordinate space, which card frames are measured in.
    nonisolated static let space = "systemPage"
    /// Room left over a card jumped to.
    nonisolated static let margin: CGFloat = 12

    /// The group of cards at the top of the visible page.
    private(set) var category: SystemCategory?
    /// The search match last gone to, which the jump bar counts from.
    private(set) var match: SystemReportSearch.Match?
    /// The match marked for a moment after going to it.
    private(set) var mark: SystemReportSearch.Match?

    @ObservationIgnored var proxy: ScrollViewProxy?
    @ObservationIgnored weak var tracker: SystemScrollTrackerView?
    /// The search's matches, as the jump bar last showed them.
    @ObservationIgnored private var matches: [SystemReportSearch.Match] = []
    @ObservationIgnored private var frames: [SystemTarget: CGRect] = [:]
    /// Until when scrolling leaves `category` alone: a group jumped to near
    /// the end of the page can't reach its top, and stays picked anyway.
    @ObservationIgnored private var heldUntil = Date.distantPast
    /// The card Refresh keeps in place, and where its top was.
    @ObservationIgnored private var anchor: (target: SystemTarget, top: CGFloat)?
    @ObservationIgnored private var markTask: Task<Void, Never>?

    // MARK: Following the page

    /// A card's (or the summary's) frame in the page, or nil once it's gone.
    func setFrame(_ frame: CGRect?, of target: SystemTarget) {
        frames[target] = frame
        if let frame, let anchor, anchor.target == target, abs(frame.minY - anchor.top) > 0.5 {
            // Something above it grew or shrank: scroll by as much.
            self.anchor = (target, frame.minY)
            tracker?.scroll(by: frame.minY - anchor.top)
        }
        follow()
    }

    /// The page scrolled.
    func scrolled() {
        follow()
    }

    private func follow() {
        guard Date.now >= heldUntil, let visible = tracker?.visiblePage else { return }
        let next = topCard(at: visible.minY).map(SystemCategory.init)
        if next != category { category = next }
    }

    /// The card at `top` (`ScrollSpy`): with two columns, the newer card to
    /// come up rather than the tail of a long one beside it.
    private func topCard(at top: CGFloat) -> InfoSection.Kind? {
        let cards = InfoSection.Kind.allCases.compactMap { kind in
            frames[.card(kind)].map { ScrollSpy.Card(kind, top: $0.minY, bottom: $0.maxY) }
        }
        return ScrollSpy.current(cards, line: top + 2 * Self.margin)
    }

    // MARK: Groups

    /// Scrolls to the highest card of `category`.
    func jump(to category: SystemCategory) {
        let cards = InfoSection.Kind.allCases.compactMap { kind in
            SystemCategory(kind) == category ? frames[.card(kind)].map { (kind: kind, frame: $0) } : nil
        }
        guard let first = cards.min(by: { $0.frame.minY < $1.frame.minY }) else { return }
        hold()
        self.category = category
        proxy?.scrollTo(SystemTarget.card(first.kind), anchor: .top)
    }

    /// The group before or after the one at the top, of `categories`.
    func step(by offset: Int, through categories: [SystemCategory]) {
        guard !categories.isEmpty else { return }
        let index = category.flatMap(categories.firstIndex(of:)).map { $0 + offset } ?? (offset > 0 ? 0 : categories.count - 1)
        guard categories.indices.contains(index) else { return }
        jump(to: categories[index])
    }

    // MARK: Search

    /// The search's matches changed (a search, a refresh, identifiers shown).
    func update(matches: [SystemReportSearch.Match]) {
        self.matches = matches
    }

    /// A new search goes to its first match. Clearing it goes back to the
    /// card the last match was in, now among the rest.
    func searchChanged(_ search: SystemReportSearch) {
        matches = search.matches
        if let first = search.matches.first {
            go(to: first)
        } else {
            let last = match
            match = nil
            mark = nil
            guard !search.isActive, let last else { return }
            hold()
            if let kind = last.kind { category = SystemCategory(kind) }
            // After the whole page is back in place.
            DispatchQueue.main.async { [self] in
                proxy?.scrollTo(SystemTarget(cardOf: last), anchor: .top)
            }
        }
    }

    /// The match before or after the one last gone to, round the ends.
    func step(match offset: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let index = match.flatMap(matches.firstIndex(of:)).map { ($0 + offset + count) % count } ?? (offset > 0 ? 0 : count - 1)
        go(to: matches[index])
    }

    /// Where `match` is among the matches, from 1, if it's still one.
    func position(of match: SystemReportSearch.Match?) -> Int? {
        match.flatMap(matches.firstIndex(of:)).map { $0 + 1 }
    }

    private func go(to match: SystemReportSearch.Match) {
        self.match = match
        hold()
        if let kind = match.kind { category = SystemCategory(kind) }
        markTask?.cancel()
        mark = match
        markTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { self?.mark = nil }
        }
        // Once the page has laid out what the search shows.
        DispatchQueue.main.async { [self] in reveal(match) }
    }

    /// Scrolls `match` into view, unless its card already is: the card's top
    /// when the card fits, otherwise the row itself in the middle.
    private func reveal(_ match: SystemReportSearch.Match) {
        let card = SystemTarget(cardOf: match)
        let visible = tracker?.visiblePage
        if let frame = frames[card], let visible, visible.insetBy(dx: -1, dy: -1).contains(frame) { return }
        if case let .row(kind, index) = match, let frame = frames[card], let visible, frame.height > visible.height - Self.margin {
            proxy?.scrollTo(SystemTarget.row(kind, index), anchor: .center)
        } else {
            proxy?.scrollTo(card, anchor: .top)
        }
    }

    // MARK: Refresh

    /// Notes the card at the top, so it stays put while Refresh's reads
    /// arrive and cards above it change length. At the very top, the page
    /// simply stays at the top.
    func holdPosition() {
        guard let visible = tracker?.visiblePage, visible.minY > 1, let kind = topCard(at: visible.minY),
              let frame = frames[.card(kind)] else { return }
        anchor = (.card(kind), frame.minY)
    }

    func releasePosition() {
        anchor = nil
    }

    private func hold() {
        heldUntil = Date.now.addingTimeInterval(0.5)
    }
}

// MARK: - Cards

extension View {
    /// Makes this card (or the summary) a place the page can jump to and
    /// notes where it's laid out. The jump lands `SystemNavigator.margin`
    /// above its top, so it doesn't butt against the jump bar.
    func systemTarget(_ target: SystemTarget, navigator: SystemNavigator) -> some View {
        background(alignment: .top) {
            Color.clear
                .frame(height: SystemNavigator.margin)
                .alignmentGuide(.top) { $0[.bottom] }
                .id(target)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SystemNavigator.space)) } action: {
            navigator.setFrame($0, of: target)
        }
        .onDisappear { navigator.setFrame(nil, of: target) }
    }

    /// Marks a whole card for a moment after a search goes to it.
    func systemCardMark(_ match: SystemReportSearch.Match, navigator: SystemNavigator) -> some View {
        modifier(SystemCardMark(match: match, navigator: navigator))
    }
}

/// A whole card's mark. Its own modifier, so only it reads the mark and the
/// page around the card isn't drawn again.
private struct SystemCardMark: ViewModifier {
    let match: SystemReportSearch.Match
    let navigator: SystemNavigator

    func body(content: Content) -> some View {
        content.overlay {
            if navigator.mark == match {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The bounds of the row a search marks, for its card to draw the mark
/// behind the whole row, label and value together.
struct MarkedRowKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    /// Reports this cell's bounds while its row is marked.
    func markedRow(_ isMarked: Bool) -> some View {
        anchorPreference(key: MarkedRowKey.self, value: .bounds) { isMarked ? [$0] : [] }
    }

    /// Draws the marked row's highlight behind this card's rows, across
    /// their full width.
    func markedRowBackground() -> some View {
        backgroundPreferenceValue(MarkedRowKey.self) { anchors in
            GeometryReader { proxy in
                if !anchors.isEmpty {
                    let row = anchors.map { proxy[$0] }.reduce(CGRect.null) { $0.union($1) }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: proxy.size.width + 12, height: row.height + 6)
                        .position(x: proxy.size.width / 2, y: row.midY)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - Jump bar

/// Over the System page's cards: a picker of the groups of cards, which
/// follows the scrolling and jumps to the group picked, and Previous and
/// Next (⌘↑ and ⌘↓). While searching it says how many matches there are,
/// and Previous and Next (⇧⌘G and ⌘G, or Return in the search field) step
/// through them. The search is named here too, with a way to clear it, since
/// a narrow toolbar folds its field away; ⌘F goes to the field.
struct SystemJumpBar: View {
    let navigator: SystemNavigator
    /// The groups with a card on the page: during a search, with a match.
    let categories: [SystemCategory]
    let search: SystemReportSearch
    @Binding var query: String
    /// Puts the cursor in the search field (⌘F).
    var find: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // A menu in place of the segments when the page is too narrow for them.
            // Ahead of the search's count, which gives way first.
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented).fixedSize()
                picker.pickerStyle(.menu).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if search.isActive {
                searching
            }
            stepper
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background {
            // No menu item to hang ⌘F on, so a button no one sees.
            Button("Find", action: find)
                .keyboardShortcut("f")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: search.matches, initial: true) { navigator.update(matches: search.matches) }
        .onChange(of: search.terms) { navigator.searchChanged(search) }
    }

    private var picker: some View {
        let selection = Binding<SystemCategory?>(get: { navigator.category }, set: { category in
            if let category { navigator.jump(to: category) }
        })
        return Picker("Jump to", selection: selection) {
            ForEach(categories) { category in
                Text(category.title).tag(Optional(category))
            }
        }
        .labelsHidden()
        .help("Jump to a group of cards. ⌘↑ and ⌘↓ step from one group to the next.")
        .accessibilityLabel("Jump to")
    }

    /// "2 of 9 for “ipv6”" and a button that clears the search.
    private var searching: some View {
        HStack(spacing: 4) {
            (Text(count).monospacedDigit() + Text(" for \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}"))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Clear the search and show every card")
            .accessibilityLabel("Clear the search")
        }
        .frame(maxWidth: 260, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "2 of 9", "9 matches", "No matches".
    private var count: String {
        let total = search.matches.count
        guard total > 0 else { return "No matches" }
        if let position = navigator.position(of: navigator.match) { return "\(position) of \(total)" }
        return total == 1 ? "1 match" : "\(total) matches"
    }

    private var stepper: some View {
        let searching = search.isActive
        let none = searching ? search.matches.isEmpty : categories.isEmpty
        return ControlGroup {
            Button {
                if searching { navigator.step(match: -1) } else { navigator.step(by: -1, through: categories) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut(searching ? KeyboardShortcut("g", modifiers: [.command, .shift]) : KeyboardShortcut(.upArrow, modifiers: .command))
            .help(searching ? "Previous match (⇧⌘G)" : "Previous group of cards (⌘↑)")
            .accessibilityLabel(searching ? "Previous match" : "Previous group")
            Button {
                if searching { navigator.step(match: 1) } else { navigator.step(by: 1, through: categories) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut(searching ? KeyboardShortcut("g", modifiers: .command) : KeyboardShortcut(.downArrow, modifiers: .command))
            .help(searching ? "Next match (⌘G or Return)" : "Next group of cards (⌘↓)")
            .accessibilityLabel(searching ? "Next match" : "Next group")
        }
        .disabled(none)
        .fixedSize()
    }
}

// MARK: - Scrolling

/// Sits behind the System page's content to follow its scroll view: where
/// the visible part is in page coordinates, and a nudge to keep a card in
/// place while Refresh changes what's above it.
struct SystemScrollTracker: NSViewRepresentable {
    let navigator: SystemNavigator

    func makeNSView(context: Context) -> SystemScrollTrackerView {
        let view = SystemScrollTrackerView()
        view.navigator = navigator
        navigator.tracker = view
        return view
    }

    func updateNSView(_ view: SystemScrollTrackerView, context: Context) {
        view.navigator = navigator
        navigator.tracker = view
    }
}

final class SystemScrollTrackerView: NSView {
    var navigator: SystemNavigator?
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
    }

    @objc private func pageScrolled(_ notification: Notification) {
        navigator?.scrolled()
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

    /// Scrolls the page by `distance` points, down the page when positive.
    func scroll(by distance: CGFloat) {
        guard let clip, let scrollView = enclosingScrollView else { return }
        var bounds = clip.bounds
        bounds.origin.y += clip.isFlipped ? distance : -distance
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
