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

    @Test func trailsNameEachFolderBelowTheOneOpen() {
        #expect(Format.trail("/demo/Projects/webapp/build", under: "/demo") == "Projects › webapp › build")
        #expect(Format.trail("/demo/Projects/webapp/build", under: "/demo/Projects") == "webapp › build")
        #expect(Format.trail("Projects/webapp/build") == "Projects › webapp › build", "below the scanned folder")
        #expect(Format.trail("Projects/webapp", under: "Projects") == "webapp")
        #expect(Format.trail("/demo/Projects/", under: "/demo/") == "Projects", "trailing slashes don't count")
        #expect(Format.trail("/demo", under: "/demo") == "", "the folder itself")
        #expect(Format.trailNames("/demo/Projects/webapp/build", under: "/demo") == ["Projects", "webapp", "build"])
        #expect(Format.trailNames("/demo", under: "/demo").isEmpty)
    }

    @Test func trailsMatchWholeFolderNames() {
        // "Projects2" isn't inside "Projects", and a path outside keeps its whole trail.
        #expect(Format.trail("Projects2/app", under: "Projects") == "Projects2 › app")
        #expect(Format.trail("/other/file.bin", under: "/demo") == "other › file.bin")
        #expect(Format.trail("/demo", under: "/demo/Projects") == "demo")
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

    @Test func roughDurationsRoundForAGlance() {
        #expect(Format.roughDuration(0) == "0 s")
        #expect(Format.roughDuration(45) == "45 s")
        // Just short of a minute rounds up to it rather than reading "60 s".
        #expect(Format.roughDuration(59.6) == "1 min")
        #expect(Format.roughDuration(17 * 60 + 20) == "17 min")
        #expect(Format.roughDuration(3_599) == "1 h")
        #expect(Format.roughDuration(5 * 3_600 + 40 * 60) == "5 h 40 min")
        #expect(Format.roughDuration(24 * 3_600 - 10) == "1 day")
        #expect(Format.roughDuration(27 * 3_600) == "1 day 3 h")
        #expect(Format.roughDuration(6 * 86_400) == "6 days")
        #expect(Format.roughDuration(-1) == "—")
        #expect(Format.roughDuration(.nan) == "—")
    }

    @Test func agoTakesOneWholeUnit() {
        #expect(Format.ago(0) == "just now")
        #expect(Format.ago(59.9) == "just now")
        #expect(Format.ago(60) == "1 min ago")
        // Rounded down: it was 59 minutes, not yet an hour.
        #expect(Format.ago(3_599) == "59 min ago")
        #expect(Format.ago(2 * 3_600 + 50 * 60) == "2 h ago")
        #expect(Format.ago(86_400) == "1 day ago")
        #expect(Format.ago(3 * 86_400 + 5) == "3 days ago")
        #expect(Format.ago(-30) == "just now")
        #expect(Format.ago(.nan) == "—")
    }

    @Test func sensorReadings() {
        #expect(Format.celsius(61.6) == "62 °C")
        #expect(Format.celsius(.nan) == "—")
        #expect(Format.rpm(1357.4).hasSuffix(" rpm"))
        #expect(Format.rpm(0) == "0 rpm")
    }
}
