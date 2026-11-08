import OTMKit
import SwiftUI

/// One key explains the step track and busy readings without labelling every idle stretch.
struct HistoryProcessMemoryLegend: View {
    let showsBusy: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            item("Memory kept while idle", stroke: .dashed,
                 help: "The step track keeps changes of at least 10% or 16 MB, or any change after 30 minutes.")
            if showsBusy {
                item("Busy figures", stroke: .solid, help: "Memory kept with CPU or disk figures in busy records.")
            }
            HStack(spacing: 5) {
                Canvas { context, size in
                    HistoryCoverage.drawGaps([CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)],
                                             in: context, dark: colorScheme == .dark)
                }
                .frame(width: 18, height: 11)
                Text("Not recorded")
            }
            .help("Gaps have no memory figures: History was not watching this process then.")
        }
        .font(.tableText)
        .foregroundStyle(.secondaryText)
    }

    private func item(_ name: String, stroke: HistoryLine.Stroke, help: String) -> some View {
        HStack(spacing: 5) {
            HistoryLineSample(line: HistoryLine(name: name, color: Theme.memory, value: { _ in nil },
                                                fill: stroke == .solid, stroke: stroke, meaning: help))
            Text(name)
        }
        .help(help)
    }
}
