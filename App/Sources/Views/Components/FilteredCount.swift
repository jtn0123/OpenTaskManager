import SwiftUI

/// Beside a table's filters, right over the table: how many rows the filters
/// and search leave of all there are, and the way back to all of them, so a
/// short list reads as filtered rather than as all there is. Nothing while
/// every row shows; the status bar gives the total.
struct FilteredCount: View {
    var shown: Int
    var total: Int
    /// "extensions", "items", "apps".
    var noun: String
    var showAll: () -> Void

    var body: some View {
        if shown < total {
            HStack(spacing: 8) {
                Text("Showing \(shown.formatted()) of \(total.formatted()) \(noun)")
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                Button("Show All", action: showAll)
                    .buttonStyle(.link)
                    .help("Clear the filters and the search")
            }
            .font(.metadata)
            .lineLimit(1)
            .fixedSize()
        }
    }
}
