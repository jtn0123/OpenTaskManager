import AppKit
import OTMKit
import SwiftUI

/// A value someone may want to paste elsewhere (a path, an address, an
/// identifier): selectable, monospaced by default, with a copy button that
/// appears while the pointer is over it. Long values wrap rather than
/// truncate, so the whole value is always there to read and select, unless
/// `truncatesMiddle` keeps them to one line.
struct CopyableText: View {
    var value: String
    var monospaced = true
    /// One line, cut in the middle, with the whole value in a tooltip: for
    /// identifiers too long for their line (a UUID) and paths in lists.
    var truncatesMiddle = false
    /// A file path as its name, prominent, over the folder that holds it
    /// (`PathParts`), which wraps: for paths in a details pane, where a cut
    /// in the middle hid the folders that tell two places apart. Still one
    /// control, the whole path in its tooltip and copied whole.
    var splitsPath = false
    /// The value broken over more and more lines where it reads best (an
    /// address between its groups, never before its prefix; see
    /// `AddressBreaks`), for when it doesn't fit on its own lines. The first
    /// form that fits shows; copying always takes `value`.
    var forms: [String] = []
    /// A search's words (the System page's), marked wherever the value holds them.
    @Environment(\.searchTerms) private var searchTerms
    @Environment(\.isCurrentSearchMatch) private var isCurrentMatch
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
            .help(splitsPath ? "Copy Path" : "Copy")
            .accessibilityLabel(splitsPath ? "Copy Path" : "Copy")
            // Hidden rather than removed, so the text doesn't reflow on hover.
            .opacity(isHovering || copied ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var text: some View {
        if splitsPath {
            let parts = PathParts(value)
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.name)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let folder = parts.folder {
                    styled(folder)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(value)
        } else if truncatesMiddle {
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
        marked(text).monospaced(monospaced).textSelection(.enabled)
    }

    /// `text` (the value, or a form of it) with a search's finds in the
    /// value marked, across a form's line breaks too.
    private func marked(_ text: String) -> Text {
        guard !searchTerms.isEmpty else { return Text(text) }
        let ranges = SystemReportSearch.highlights(of: searchTerms, in: value, shownAs: text)
        return Text(SearchMarks.attributed(text, marking: ranges, current: isCurrentMatch))
    }
}
