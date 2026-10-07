import Foundation
@testable import OTMKit
import Testing

private func process(_ pid: Int32, responsible: Int32? = nil, uid: UInt32 = 501) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: 1, responsiblePID: responsible ?? pid, uid: uid, userName: "me", name: "p\(pid)", executablePath: nil,
        state: .running, nice: 0, startTime: nil, isTranslated: false, isRestricted: false, cpuPercent: 0, cpuTime: 0,
        memory: 0, residentMemory: 0, threadCount: 1, diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
    )
}

private func rate(_ pid: Int32, in received: Double, out sent: Double) -> ProcessNetworkRate {
    ProcessNetworkRate(pid: pid, name: "p\(pid)", bytesInPerSecond: received, bytesOutPerSecond: sent)
}

private func usage(_ total: Double) -> NetworkUsage {
    NetworkUsage(received: total, sent: 0)
}

struct NetworkActivityTests {
    @Test func helpersRollUpIntoTheirApp() throws {
        // 100 is an app with two helpers (one nested further), 200 a lone daemon.
        let groups = ProcessTreeBuilder.build(
            [process(100), process(101, responsible: 100), process(102, responsible: 101), process(200)],
            mode: .grouped, appPIDs: [100], currentUID: 501
        )
        let owners = NetworkGrouping.owners(groups)
        #expect(owners == [100: 100, 101: 100, 102: 100, 200: 200])
        // Section rows are looked through, so the flattened groups give the same map.
        #expect(NetworkGrouping.owners(groups.flatMap(\.children)) == owners)

        let usage = NetworkGrouping.byApp(
            [rate(101, in: 1_000, out: 10), rate(102, in: 500, out: 0), rate(200, in: 0, out: 40), rate(300, in: 7, out: 0)],
            owners: owners
        )
        let app = try #require(usage[100])
        #expect(app.received == 1_500)
        #expect(app.sent == 10)
        #expect(app.processes == 2)
        #expect(usage[200]?.total == 40)
        // A process the list doesn't know yet stands for itself.
        #expect(usage[300]?.processes == 1)
        #expect(usage.count == 3)
    }

    @Test func byProcessKeepsEachProcessApart() {
        let usage = NetworkGrouping.byProcess([rate(101, in: 1_000, out: 10), rate(102, in: 500, out: 5)])
        #expect(usage[101] == NetworkUsage(received: 1_000, sent: 10))
        #expect(usage[102]?.total == 505)
    }

    @Test func seriesLineUpAndTrimToTheWindow() {
        var history = NetworkActivityHistory<Int32>(capacity: 3)
        #expect(history.isEmpty)
        history.append([1: usage(10)])
        history.append([1: usage(20), 2: usage(5)])
        // The newcomer is padded back to the start of the window.
        #expect(history.totals[1] == [10, 20])
        #expect(history.totals[2] == [0, 5])
        history.append([2: usage(6)])
        history.append([2: usage(7)])
        // Oldest readings fall off at capacity.
        #expect(history.length == 3)
        #expect(history.totals[1] == [20, 0, 0])
        #expect(history.totals[2] == [5, 6, 7])
        #expect(history.latest.keys.sorted() == [2])
        // Quiet for the whole window: dropped.
        history.append([2: usage(1)])
        #expect(history.totals[1] == nil)
        #expect(history.totals.count == 1)
        #expect(!history.isQuiet)

        history.append([:])
        history.append([:])
        history.append([:])
        #expect(history.isQuiet)
        #expect(history.latest.isEmpty)
        #expect(history.length == 3)

        history.removeAll()
        #expect(history.isEmpty)
    }

    @Test func rankingBandsTheBusiestAndListsWhatsMovingNow() {
        var history = NetworkActivityHistory<Int32>(capacity: 10)
        history.append([1: usage(1_000), 2: usage(100), 3: usage(50)])
        history.append([1: usage(900), 2: usage(100), 4: usage(10)])
        // App 1 went quiet; 5 just started and leads right now.
        history.append([2: usage(100), 3: usage(40), 5: usage(300)])

        let ranking = history.ranking(bands: 2, rows: 4)
        #expect(ranking.bands == [1, 2])
        // Busiest now first; the quiet band keeps a row at the end.
        #expect(ranking.rows == [5, 2, 3, 1])
        #expect(history.ranking(bands: 0, rows: 2).rows == [5, 2])
        #expect(history.ranking(bands: 9, rows: 9).bands.count == 5)
    }

    @Test func remainderSumsEverythingOutsideTheBands() {
        var history = NetworkActivityHistory<Int32>(capacity: 4)
        history.append([1: usage(10), 2: usage(3)])
        history.append([1: usage(10), 3: usage(4)])
        history.append([2: NetworkUsage(received: 1, sent: 1)])
        #expect(history.remainder(excluding: [1]) == [3, 4, 2])
        #expect(history.remainder(excluding: [1, 2, 3]) == [0, 0, 0])
        #expect(history.volume(1) == 20)
        #expect(history.volume(9) == 0)
    }

    @Test func ratesFromTwoReadingsFeedTheHistory() throws {
        // The whole path: cumulative counts, to rates, to apps, to the window.
        let before: [Int32: ProcessTraffic] = [
            100: ProcessTraffic(pid: 100, name: "app", bytesIn: 0, bytesOut: 0),
            101: ProcessTraffic(pid: 101, name: "helper", bytesIn: 1_000, bytesOut: 0),
        ]
        let after: [Int32: ProcessTraffic] = [
            100: ProcessTraffic(pid: 100, name: "app", bytesIn: 300, bytesOut: 0),
            101: ProcessTraffic(pid: 101, name: "helper", bytesIn: 7_000, bytesOut: 3_000),
        ]
        let rates = ProcessNetwork.rates(from: before, to: after, interval: 3)
        var history = NetworkActivityHistory<Int32>(capacity: 5)
        history.append(NetworkGrouping.byApp(rates, owners: [100: 100, 101: 100]))
        let app = try #require(history.latest[100])
        #expect(app.received == 2_100)
        #expect(app.sent == 1_000)
        #expect(app.processes == 2)
        #expect(history.totals[100] == [3_100])
    }
}
