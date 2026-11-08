import Foundation
@testable import OTMKit
import Testing

struct HistoryControlLabelsTests {
    @Test func changeHeadingNamesItsDirectionAndCellsReadAloud() {
        #expect(HistoryCompareLabels.changeHeading == "Change, A vs B")
        let cpu = HistoryComparison.Change(a: 0.42, b: 0.30)
        #expect(cpu.label(isFraction: true) == "+12 pts")
        #expect(cpu.spokenLabel(isFraction: true) == "A is 12 points higher than B")
        let falling = HistoryComparison.Change(a: 0.20, b: 0.231)
        #expect(falling.label(isFraction: true) == "\u{2212}3.1 pts")
        #expect(falling.spokenLabel(isFraction: true) == "A is 3.1 points lower than B")
        let bytes = HistoryComparison.Change(a: 1_024, b: 3_072)
        #expect(bytes.label(isFraction: false) == "\u{2212}67%")
        #expect(bytes.spokenLabel(isFraction: false) == "A is 67% lower than B")
        #expect(HistoryComparison.Change(a: 1_200, b: 100).spokenLabel(isFraction: false) == "A is 12 times B")
        #expect(HistoryComparison.Change(a: 1_000, b: 0).spokenLabel(isFraction: false) == "A has some where B had none")
        let temperature = HistoryComparison.Change(a: 56.4, b: 60.5, absoluteUnit: .celsius)
        #expect(temperature.spokenLabel(isFraction: false) == "A is 4.1 °C lower than B")
    }

    @Test func sameFiguresHaveNoDirection() {
        for change in [HistoryComparison.Change(a: 0, b: 0), HistoryComparison.Change(a: 0.5, b: 0.5002)] {
            #expect(change.label(isFraction: true) == "no change")
            #expect(change.spokenLabel(isFraction: true) == "A and B are the same at the shown precision")
        }
    }

    @Test func compactCoveragePreservesZeroAndTinyShares() {
        #expect(HistoryCompareLabels.detailsTitle(expanded: false, compact: true) == "More")
        #expect(HistoryCompareLabels.detailsTitle(expanded: true, compact: true) == "Less")
        #expect(HistoryCompareLabels.detailsTitle(expanded: false, compact: false) == "All Figures")
        #expect(HistoryCompareLabels.detailsTitle(expanded: true, compact: false) == "Fewer Figures")
        #expect(HistoryCompareLabels.coverage(0, compact: true) == "0%")
        #expect(HistoryCompareLabels.coverage(0.001, compact: true) == "<1%")
        #expect(HistoryCompareLabels.coverage(0.73, compact: true) == "73%")
        #expect(HistoryCompareLabels.coverage(1, compact: true) == "100%")
        #expect(HistoryCompareLabels.coverage(0.73, compact: false) == "73% recorded")
        let low = HistoryComparison.Limitation(kind: .low, sides: [.a, .b], message: "")
        #expect(HistoryCompareLabels.notice(low) == "Little recorded in A and B; changes may reflect gaps.")
        let uneven = HistoryComparison.Limitation(kind: .uneven, sides: [.b], message: "")
        #expect(HistoryCompareLabels.notice(uneven) == "Less recorded in B; changes may reflect gaps.")
    }

    @Test func liveTitlesDistinguishReplayAndKeepTheShortFormNarrow() {
        for paused in [false, true] {
            let action = paused ? "Resume" : "Pause"
            for replaying in [false, true] {
                #expect(UpdateControlLabels.liveTitle(paused: paused, replaying: replaying)
                    == action + (replaying ? " Live" : ""))
                #expect(UpdateControlLabels.liveTitle(paused: paused, replaying: replaying, compact: true) == action)
                #expect(UpdateControlLabels.liveMenuTitle(paused: paused, replaying: replaying)
                    == action + (replaying ? " Live" : " Updates"))
                #expect(UpdateControlLabels.liveHelp(paused: paused, replaying: replaying).hasPrefix(action + " live updates"))
                #expect(UpdateControlLabels.liveHelp(paused: paused, replaying: replaying).contains("History replay") == replaying)
            }
            #expect(UpdateControlLabels.liveAccessibility(paused: paused) == action + " Live")
        }
    }

    @Test func replayTitlesNameTheReplayInEveryState() {
        #expect(UpdateControlLabels.replayTitle(playing: true, hasPlayhead: false) == "Pause Replay")
        #expect(UpdateControlLabels.replayTitle(playing: true, hasPlayhead: true) == "Pause Replay")
        #expect(UpdateControlLabels.replayTitle(playing: false, hasPlayhead: true) == "Resume Replay")
        #expect(UpdateControlLabels.replayTitle(playing: false, hasPlayhead: false) == "Play Replay")
        #expect(UpdateControlLabels.replayHelp(playing: true).contains("Live updates are controlled separately"))
        #expect(UpdateControlLabels.replayHelp(playing: false).contains("skipping what wasn't recorded"))
    }

    @Test func gapTooltipIncludesTheSpanAndPossibleCauses() {
        #expect(HistoryGapLabels.help(span: "10:00 – 10:02 AM", duration: "2 min")
            == "Not recorded · 10:00 – 10:02 AM · 2 min. The app wasn't running, the Mac slept, or live updates were paused. "
                + "Every figure leaves this gap out.")
    }
}
