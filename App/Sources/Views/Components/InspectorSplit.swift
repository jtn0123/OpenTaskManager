import AppKit
import OTMKit
import SwiftUI

/// A list with an inspector pane beside it while both fit at their minimum
/// widths; dragging the pane's leading edge resizes it. In a narrower window
/// the inspector covers the list instead, under a Back button. The list stays
/// in place underneath, so its selection, sorting and scroll position survive.
///
/// This is an HStack rather than `.inspector`, whose column, with a toolbar
/// search field, pushed narrow windows' content past both edges.
struct InspectorSplit<Content: View, Detail: View>: View {
    static var minimumWidth: CGFloat { 280 }
    static var maximumWidth: CGFloat { 480 }

    /// Narrowest the list can be without scrolling sideways.
    var listMinimum: CGFloat
    /// Something is selected and the inspector is switched on.
    var wantsInspector: Bool
    /// In a narrow window, whether the inspector covers the list.
    @Binding var coversList: Bool
    /// Set while the window is too narrow for both side by side.
    @Binding var isNarrow: Bool
    var backTitle: String
    var content: Content
    var detail: Detail

    @AppStorage private var preferredWidth: Double
    @State private var available: CGFloat?
    @State private var drag: (start: Double, width: Double)?

    init(
        listMinimum: CGFloat,
        wantsInspector: Bool,
        coversList: Binding<Bool>,
        isNarrow: Binding<Bool>,
        widthKey: String,
        backTitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.listMinimum = listMinimum
        self.wantsInspector = wantsInspector
        _coversList = coversList
        _isNarrow = isNarrow
        _preferredWidth = AppStorage(wrappedValue: 320, widthKey)
        self.backTitle = backTitle
        self.content = content()
        self.detail = detail()
    }

    var body: some View {
        let paneWidth = available.flatMap(paneWidth(in:))
        // Until the first measurement, assume there's room.
        let narrow = available != nil && paneWidth == nil
        HStack(spacing: 0) {
            ZStack {
                content
                if narrow, coversList {
                    VStack(spacing: 0) {
                        backBar
                        Divider()
                        detail
                    }
                    .background(.background)
                }
            }
            if let paneWidth, wantsInspector {
                Divider()
                detail
                    .frame(width: paneWidth)
                    .overlay(alignment: .leading) { resizeHandle }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .onChange(of: narrow) {
            isNarrow = narrow
            // Keep showing what was on screen: an open pane covers the list
            // when the window gets too narrow, and moves back beside it when
            // there's room again.
            coversList = narrow && wantsInspector
        }
    }

    private func paneWidth(in available: CGFloat) -> CGFloat? {
        SplitMath.inspectorWidth(
            available: available, listMinimum: listMinimum, preferred: drag?.width ?? preferredWidth,
            minimum: Self.minimumWidth, maximum: Self.maximumWidth
        ).map { CGFloat($0) }
    }

    private var backBar: some View {
        HStack {
            Button {
                coversList = false
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the list (Esc)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A strip along the pane's leading edge, inside the pane so the table
    /// beside it never competes for the drag.
    private var resizeHandle: some View {
        ResizeHandle { offset in
            let start = drag?.start ?? available.flatMap(paneWidth(in:)).map(Double.init) ?? preferredWidth
            // Dragging left widens the pane.
            drag = (start, start - offset)
        } onEnd: {
            // Save the width as shown, already kept within bounds.
            if let width = available.flatMap(paneWidth(in:)) { preferredWidth = Double(width) }
            drag = nil
        }
        .frame(width: 6)
    }
}

/// Drag strip for a pane's edge. AppKit rather than a SwiftUI gesture: the
/// resize cursor comes from a cursor rect, which can't get stuck the way a
/// hover push and pop can when the pane goes away under the pointer.
private struct ResizeHandle: NSViewRepresentable {
    /// Horizontal distance the pointer has moved since the drag began.
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        /// In window coordinates, which stay put while the pane moves.
        private var startX: CGFloat = 0

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            onEnd?()
        }
    }
}
