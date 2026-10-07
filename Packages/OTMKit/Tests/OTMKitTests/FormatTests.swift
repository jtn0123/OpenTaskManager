@testable import OTMKit
import Testing

struct FormatTests {
    @Test(arguments: [
        (UInt64(0), "0 B"),
        (UInt64(1023), "1023 B"),
        (UInt64(1024), "1.00 KB"),
        (UInt64(1536), "1.50 KB"),
        (UInt64(10 * 1024 * 1024), "10.0 MB"),
        (UInt64(512) * 1024 * 1024 * 1024, "512 GB"),
    ])
    func bytes(value: UInt64, expected: String) {
        #expect(Format.bytes(value) == expected)
    }

    @Test func bitsPerSecondUsesDecimalUnits() {
        #expect(Format.bitsPerSecond(0) == "0 bps")
        #expect(Format.bitsPerSecond(125) == "1.0 Kbps")
        #expect(Format.bitsPerSecond(1_250_000) == "10.0 Mbps")
        #expect(Format.bitsPerSecond(125_000_000) == "1.0 Gbps")
    }

    @Test func percent() {
        #expect(Format.percent(0.256) == "26%")
        #expect(Format.percent(0.256, digits: 1) == "25.6%")
        #expect(Format.percent(.nan) == "—")
    }

    @Test func watts() {
        #expect(Format.watts(0) == "0 W")
        #expect(Format.watts(0.25) == "250 mW")
        #expect(Format.watts(0.004) == "4 mW")
        #expect(Format.watts(0.0001) == "0 W")
        #expect(Format.watts(3.456) == "3.46 W")
        #expect(Format.watts(42.04) == "42.0 W")
    }

    @Test func frequency() {
        #expect(Format.frequency(megahertz: 338) == "338 MHz")
        #expect(Format.frequency(megahertz: 999.6) == "1.00 GHz")
        #expect(Format.frequency(megahertz: 4608) == "4.61 GHz")
        #expect(Format.frequency(megahertz: .nan) == "—")
    }

    @Test func duration() {
        #expect(Format.duration(5) == "5s")
        #expect(Format.duration(65) == "1m 05s")
        #expect(Format.duration(3 * 3600 + 7 * 60) == "3h 07m")
        #expect(Format.duration(2 * 86_400 + 5 * 3600) == "2d 5h")
    }

    @Test func cpuTime() {
        #expect(Format.cpuTime(0) == "00:00.00")
        #expect(Format.cpuTime(75.5) == "01:15.50")
        #expect(Format.cpuTime(3725.01) == "1:02:05.01")
    }
}

struct HistoryTests {
    @Test func keepsInsertionOrderBeforeWrapping() {
        var history = History<Int>(capacity: 4)
        for value in 1...3 { history.append(value) }
        #expect(history.values == [1, 2, 3])
        #expect(history.last == 3)
    }

    @Test func dropsOldestAfterWrapping() {
        var history = History<Int>(capacity: 3)
        for value in 1...7 { history.append(value) }
        #expect(history.values == [5, 6, 7])
        #expect(history.count == 3)
        #expect(history.last == 7)
    }

    @Test func removeAllResets() {
        var history = History<Int>(capacity: 2)
        for value in 1...5 { history.append(value) }
        history.removeAll()
        #expect(history.isEmpty)
        history.append(9)
        #expect(history.values == [9])
    }

    @Test func timeSpansReadNaturally() {
        #expect(Format.timeSpan(0.5) == "0.5 s")
        #expect(Format.timeSpan(1) == "1 s")
        #expect(Format.timeSpan(30) == "30 s")
        #expect(Format.timeSpan(60) == "1 min")
        #expect(Format.timeSpan(150) == "2 min 30 s")
        #expect(Format.timeSpan(300) == "5 min")
        #expect(Format.timeSpan(1500) == "25 min")
        #expect(Format.timeSpan(3600) == "1 h")
        #expect(Format.timeSpan(5400) == "1 h 30 min")
        #expect(Format.timeSpan(-1) == "—")
    }
}
