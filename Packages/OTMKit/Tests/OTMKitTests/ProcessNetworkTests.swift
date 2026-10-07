import Foundation
@testable import OTMKit
import Testing

struct ProcessNetworkTests {
    @Test func parsesNettopRowsFromTheRight() {
        let output = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        mDNSResponder.690,11444663,1669102,
        2.1.292.39344,3720957,22094563,
        odd,name.77,5,6,
        not a row
        """
        let traffic = ProcessNetwork.parse(output)
        #expect(traffic.count == 4)
        #expect(traffic[690] == ProcessTraffic(pid: 690, name: "mDNSResponder", bytesIn: 11_444_663, bytesOut: 1_669_102))
        #expect(traffic[39344]?.name == "2.1.292")
        #expect(traffic[77]?.name == "odd,name")
        #expect(traffic[1]?.bytesIn == 0)
    }

    @Test func ratesAreBusiestFirstAndSkipNewOrReusedProcesses() {
        let old: [Int32: ProcessTraffic] = [
            1: ProcessTraffic(pid: 1, name: "quiet", bytesIn: 10, bytesOut: 10),
            2: ProcessTraffic(pid: 2, name: "busy", bytesIn: 1_000, bytesOut: 0),
            3: ProcessTraffic(pid: 3, name: "before", bytesIn: 500, bytesOut: 500),
            4: ProcessTraffic(pid: 4, name: "upload", bytesIn: 0, bytesOut: 0),
        ]
        let new: [Int32: ProcessTraffic] = [
            1: ProcessTraffic(pid: 1, name: "quiet", bytesIn: 10, bytesOut: 10),
            2: ProcessTraffic(pid: 2, name: "busy", bytesIn: 7_000, bytesOut: 2_000),
            // The PID now belongs to another process.
            3: ProcessTraffic(pid: 3, name: "after", bytesIn: 900, bytesOut: 900),
            4: ProcessTraffic(pid: 4, name: "upload", bytesIn: 0, bytesOut: 4_000),
            5: ProcessTraffic(pid: 5, name: "new", bytesIn: 50, bytesOut: 50),
        ]
        let rates = ProcessNetwork.rates(from: old, to: new, interval: 2)
        #expect(rates.map(\.pid) == [2, 4])
        #expect(rates[0].bytesInPerSecond == 3_000)
        #expect(rates[0].bytesOutPerSecond == 1_000)
        #expect(rates[1].total == 2_000)
        #expect(ProcessNetwork.rates(from: old, to: new, interval: 0).isEmpty)
    }

    @Test func readsThisMac() throws {
        // nettop needs no special rights, and mDNSResponder alone always has sockets.
        let traffic = try #require(ProcessNetwork.read())
        #expect(!traffic.isEmpty)
        #expect(traffic.values.allSatisfy { !$0.name.isEmpty })
        // Real interfaces only: on a quiet machine that may be no process at all, but nettop still answers.
        let external = try #require(ProcessNetwork.read(excludingLoopback: true))
        #expect(external.values.allSatisfy { !$0.name.isEmpty })
    }
}
