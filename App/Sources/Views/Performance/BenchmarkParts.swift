import OTMKit
import SwiftUI

/// "Methodology" at the foot of a benchmark card or section: what the test
/// does and how its figures are taken, folded away so the figures come
/// first. Folded, the line beside the title says in brief what it holds.
/// Warnings that change what a figure means stay out of it, beside the figures.
struct MethodologyDisclosure<Content: View>: View {
    /// What the test measures, in a line: "FP32 compute, memory and fill rate · about 10 s".
    var preview: String
    @ViewBuilder var content: Content
    @State private var isExpanded = false

    var body: some View {
        DetailDisclosure("Methodology", preview: preview, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

/// "Timing unverified" with a caution mark, right under a figure in doubt,
/// the reason and the measured timing in its tooltip.
struct FigureCaveatLabel: View {
    var caveat: BenchmarkFigureCaveat
    /// What was measured, after the reason: "449 ms on the GPU, 492 ms from commit to completion".
    var detail: String?

    var body: some View {
        Label(caveat.title, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(BenchmarkLook.caution)
            .lineLimit(1)
            .help(caveat.explanation + (detail.map { " Each repeat: \($0)." } ?? ""))
    }
}

/// The caution mark alone, before a figure in a table of runs.
struct FigureCaveatMark: View {
    var caveat: BenchmarkFigureCaveat

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .imageScale(.small)
            .foregroundStyle(BenchmarkLook.caution)
            .accessibilityLabel(caveat.title)
    }
}

/// Under a table of runs where a figure is marked: what the mark means, in a line.
struct FigureCaveatFootnote: View {
    var caveat: BenchmarkFigureCaveat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            FigureCaveatMark(caveat: caveat)
            Text("\(caveat.title): \(caveat.brief).")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(caveat.explanation)
    }
}

// MARK: - Scrolling the workspace

/// What the Benchmarks workspace scrolls to: a test's section, or its comparison.
enum BenchmarkAnchor {
    static func section(_ kind: BenchmarkKind) -> String { "benchmark-section-\(kind.rawValue)" }
    static func comparison(_ kind: BenchmarkKind) -> String { "benchmark-compare-\(kind.rawValue)" }
}

extension EnvironmentValues {
    /// How far over a scroll target the workspace's pinned strip reaches.
    @Entry var benchmarkScrollClearance: CGFloat = 0
}

/// Marks a view as a scroll target that starts `benchmarkScrollClearance`
/// above it, so a jump to the top lands the view under the pinned strip,
/// not behind it.
struct BenchmarkScrollAnchor: ViewModifier {
    let id: String
    @Environment(\.benchmarkScrollClearance) private var clearance

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .id(id)
                .padding(.top, -clearance)
                .allowsHitTesting(false)
        }
    }
}
