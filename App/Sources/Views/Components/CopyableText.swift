import AppKit
import SwiftUI

/// A value someone may want to paste elsewhere (a path, an address, an
/// identifier): selectable, monospaced by default, with a copy button that
/// appears while the pointer is over it. Long values wrap rather than
/// truncate, so the whole value is always there to read and select, unless
/// `truncatesMiddle` keeps them to one line.
struct CopyableText: View {
    var value: String
    var monospaced = true
    /// One line, cut in the middle so the start and the file name both show,
    /// with the whole value in a tooltip: for paths in a details pane, where
    /// wrapped paths made the details too long to take in.
    var truncatesMiddle = false
    /// The value broken over more and more lines where it reads best (an
    /// address between its groups, never before its prefix; see
    /// `AddressBreaks`), for when it doesn't fit on its own lines. The first
    /// form that fits shows; copying always takes `value`.
    var forms: [String] = []
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            text
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy")
            // Hidden rather than removed, so the text doesn't reflow on hover.
            .opacity(isHovering || copied ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var text: some View {
        if truncatesMiddle {
            styled(value).lineLimit(1).truncationMode(.middle).help(value)
        } else if let last = forms.last {
            ViewThatFits(in: .horizontal) {
                styled(value).fixedSize()
                ForEach(forms.dropLast(), id: \.self) { styled($0).fixedSize() }
                // Narrower still, the last form wraps as it must.
                styled(last).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            styled(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func styled(_ text: String) -> some View {
        Text(text).monospaced(monospaced).textSelection(.enabled)
    }
}
