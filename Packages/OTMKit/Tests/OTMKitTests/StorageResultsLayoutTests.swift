@testable import OTMKit
import Testing

struct StorageResultsLayoutTests {
    @Test func aShortWindowReservesTheMapBeforeThePanel() {
        // A 760-point window has less height once toolbar and status strips take their room.
        let available = 660.0
        for summary in [130.0, 180.0] {
            let footer = StorageResultsLayout.footerHeight(available: available, summary: summary)
            let panel = StorageResultsLayout.reconciliationHeight(content: 500, available: footer, header: 40)
            #expect(StorageResultsLayout.mapMinimum == 180)
            #expect(footer >= 120)
            #expect(panel + 41 <= footer)
            #expect(StorageResultsLayout.cardHeight(available: available, summary: summary, footer: panel + 41)
                >= StorageResultsLayout.cardMinimum)
        }
    }

    @Test func tallerWindowsGiveRoomWithoutUnboundedReconciliation() {
        let footer = StorageResultsLayout.footerHeight(available: 1_000, summary: 130)
        #expect(StorageResultsLayout.reconciliationHeight(content: 500, available: footer, header: 40) == 180)
        #expect(StorageResultsLayout.reconciliationHeight(content: 50, available: footer, header: 40) == 50)
        #expect(StorageResultsLayout.reconciliationHeight(content: 500, available: 30, header: 40) == 0)
        #expect(StorageResultsLayout.footerHeight(available: 100, summary: 180) == 120)
        #expect(StorageResultsLayout.cardHeight(available: 100, summary: 180, footer: 120) == StorageResultsLayout.cardMinimum)
        #expect(StorageResultsLayout.cardHeight(available: 1_000, summary: 130, footer: 220) == 594)
    }
}
