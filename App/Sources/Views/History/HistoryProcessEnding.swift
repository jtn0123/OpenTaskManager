import AppKit
import OTMKit
import SwiftUI

/// Each source says only what it witnessed, with its own time.
struct HistoryProcessEnding: View {
    let ending: ProcessEnding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How it ended").font(.tableText.weight(.semibold))
            if ending.evidence.isEmpty {
                ForEach(ending.words(clock: HistoryProcessStyle.clock), id: \.self) { words in
                    Text(words).textSelection(.enabled)
                }
            } else {
                ForEach(Array(ending.evidence.enumerated()), id: \.offset) { _, evidence in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(evidence.words(clock: HistoryProcessStyle.clock)).textSelection(.enabled)
                        if let report = evidence.report {
                            Button("Show Report") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                                .controlSize(.small)
                                .fixedSize()
                                .help("Reveal the diagnostic report in Finder")
                        }
                    }
                }
            }
        }
        .font(.explanation)
        .foregroundStyle(.secondaryText)
        .monospacedDigit()
    }
}
