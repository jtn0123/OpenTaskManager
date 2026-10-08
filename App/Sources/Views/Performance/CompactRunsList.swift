import OTMKit
import SwiftUI

/// A small run picker before the result cards, so comparing never needs a
/// trip past the charts. Full figures stay in the results and comparison.
struct CompactRunsList: View {
    let runs: [BenchmarkRun]
    let picked: [BenchmarkRun]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(runs) { run in
                GridRow {
                    Toggle("Compare", isOn: Binding(
                        get: { picked.contains { $0.id == run.id } },
                        set: { _ in BenchmarkWorkspace.shared.togglePick(run) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Compare the run of \(BenchmarkLook.when(run.date))")
                    Text(BenchmarkLook.when(run.date)).fixedSize()
                    Text(run.build?.title ?? run.context?.optimized.map { $0 ? "Release" : "Debug" } ?? "—")
                        .foregroundStyle(run.build?.optimized == false ? AnyShapeStyle(BenchmarkLook.debug) : AnyShapeStyle(.secondaryText))
                    if let figure = run.headline.first {
                        Text("\(figure.name) \(figure.unit.format(figure.value))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .lineLimit(1)
                            .help(run.headlineSummary)
                    } else {
                        Text("No figures")
                    }
                }
                .help(run.target?.name ?? run.kind.title)
            }
        }
        .font(.tableText)
        .monospacedDigit()
    }
}
