import SwiftUI

/// The toolbar's Refresh on a page that reads a list once rather than
/// following the sampling tick (Startup, Apps, Drivers), with when the list
/// was read beside it: "Read at 1:43 PM". The toolbar's live badge speaks
/// for the metrics alone, so the two never compete. The status bar says it
/// too, beside the counts. In a narrow window just the time shows, "1:43
/// PM", with "Read at" in its tooltip, so the page's other items keep their
/// place in the toolbar.
struct InventoryRefresh: View {
    /// When the list was last read; nil before the first read finishes.
    var readAt: Date?
    var isReading: Bool
    /// What Refresh reads again.
    var help: String
    var refresh: () -> Void
    @Environment(\.compactToolbar) private var isCompact

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isReading {
                    Text("Reading…")
                } else if let readAt {
                    let time = InventoryRefresh.time(readAt)
                    Text(isCompact ? time : "Read at \(time)")
                        .help("Read at \(time). This list isn't updated live: Refresh reads it again.")
                        .accessibilityLabel("Read at \(time)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
            .fixedSize()
            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(isReading)
            .help(help)
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
    }

    /// "1:43 PM", as the status bars say it.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
