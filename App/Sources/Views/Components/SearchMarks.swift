import AppKit
import OTMKit
import SwiftUI

extension EnvironmentValues {
    /// The words a page's search is marking, folded as `SystemReportSearch`
    /// folds them; none while there's no search. The System page sets it
    /// over its cards, so their labels and values mark what was found.
    @Entry var searchTerms: [String] = []
    /// Whether the text here is in the match the search has gone to, whose
    /// finds are underlined as well.
    @Entry var isCurrentSearchMatch = false
}

/// Text with a search's finds marked: a marker yellow behind them, the
/// text over it in the primary label's colour and bold, so it holds 4.5:1
/// on every card (`TextTone.highlightContrast`) and doesn't rest on colour
/// alone, and underlined in the match gone to. Where the finds are comes
/// from `SystemReportSearch.highlights`, which folds as the search does.
enum SearchMarks {
    static let wash = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tone = TextTone.highlight
        return NSColor(srgbRed: tone.red, green: tone.green, blue: tone.blue, alpha: TextTone.highlightOpacity(dark: dark))
    })

    /// `string` with `terms` marked, or plain text when there are none.
    static func text(_ string: String, terms: [String], current: Bool) -> Text {
        guard !terms.isEmpty else { return Text(string) }
        return Text(attributed(string, marking: SystemReportSearch.highlights(of: terms, in: string), current: current))
    }

    /// `string` with the stretches `ranges` marked.
    static func attributed(_ string: String, marking ranges: [Range<String.Index>], current: Bool) -> AttributedString {
        var result = AttributedString()
        var start = string.startIndex
        for range in ranges {
            result += AttributedString(string[start..<range.lowerBound])
            var found = AttributedString(string[range])
            found.backgroundColor = wash
            found.foregroundColor = .primary
            found.inlinePresentationIntent = .stronglyEmphasized
            if current { found.underlineStyle = .single }
            result += found
            start = range.upperBound
        }
        result += AttributedString(string[start...])
        return result
    }
}

/// A line of text that marks the page's search finds in it (`SearchMarks`),
/// reading the words from the environment.
struct MarkedText: View {
    var string: String
    @Environment(\.searchTerms) private var terms
    @Environment(\.isCurrentSearchMatch) private var current

    init(_ string: String) {
        self.string = string
    }

    var body: some View {
        SearchMarks.text(string, terms: terms, current: current)
    }
}
