@testable import OTMKit
import Testing

struct MemoryRateTests {
    private let before = PagingCounters(pageIns: 100, pageOuts: 10, swapIns: 0, swapOuts: 4, compressions: 1000, decompressions: 500)

    @Test func firstSampleReportsZeroRates() {
        #expect(PagingRates.between(nil, before, interval: 1, pageSize: 16384) == PagingRates())
    }

    @Test func convertsPageDeltasToBytesPerSecond() {
        let after = PagingCounters(pageIns: 164, pageOuts: 10, swapIns: 8, swapOuts: 4, compressions: 1200, decompressions: 520)
        let rates = PagingRates.between(before, after, interval: 2, pageSize: 16384)
        #expect(rates.pageIn == 64 * 16384 / 2)
        #expect(rates.pageOut == 0)
        #expect(rates.swapIn == 8 * 16384 / 2)
        #expect(rates.swapOut == 0)
        #expect(rates.compression == 200 * 16384 / 2)
        #expect(rates.decompression == 20 * 16384 / 2)
    }

    @Test func counterResetAndBadIntervalsGiveZero() {
        var reset = before
        reset.pageIns = 3
        #expect(PagingRates.between(before, reset, interval: 1, pageSize: 4096).pageIn == 0)
        #expect(PagingRates.between(before, before, interval: 0, pageSize: 4096) == PagingRates())
        #expect(PagingRates.between(before, before, interval: -1, pageSize: 4096) == PagingRates())
        #expect(PagingRates.between(before, before, interval: .infinity, pageSize: 4096) == PagingRates())
    }
}
