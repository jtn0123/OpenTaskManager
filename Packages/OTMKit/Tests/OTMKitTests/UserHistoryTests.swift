@testable import OTMKit
import Testing

struct UserHistoryTests {
    @Test func historiesKeepOnlyTheirNewestFiguresInTheSameOrder() {
        var history = UserHistory(capacity: 2)
        for value in 1...3 {
            var totals = UsageTotals()
            totals.cpuPercent = Double(value * 10)
            totals.memory = UInt64(value * 100)
            history.append(totals)
        }
        #expect(history.cpu.values == [20, 30])
        #expect(history.memory.values == [200, 300])
    }
}
