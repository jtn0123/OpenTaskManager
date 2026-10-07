import SwiftUI

/// A section of a details pane that folds away a long technical value (a
/// job's arguments, a certificate chain), so the pane keeps a single scroll
/// view rather than boxing the value in a scroll view of its own. Folded, a
/// line beside the title previews what it holds. The whole title row toggles
/// it, not just the chevron.
struct DetailDisclosure<Content: View>: View {
    var title: String
    /// What it holds, in a line, shown while folded.
    var preview: String?
    @Binding var isExpanded: Bool
    var content: Content

    init(_ title: String, preview: String? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.preview = preview
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                        .foregroundStyle(.secondaryText)
                    Text(title).foregroundStyle(.secondaryText)
                    if !isExpanded, let preview {
                        Text(preview).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content.padding(.leading, 14)
            }
        }
    }
}
