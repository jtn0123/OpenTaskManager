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
        let text = Text(value).monospaced(monospaced).textSelection(.enabled)
        if truncatesMiddle {
            text.lineLimit(1).truncationMode(.middle).help(value)
        } else {
            text.fixedSize(horizontal: false, vertical: true)
        }
    }
}
