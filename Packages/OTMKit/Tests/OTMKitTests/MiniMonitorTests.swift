import CoreGraphics
import OTMKit
import Testing

struct MiniMonitorTests {
    private let visible = CGRect(x: 0, y: 40, width: 1600, height: 935)
    private let size = CGSize(width: 220, height: 160)

    private func figures(cpu: Double, gpu: Double? = nil, watts: Double? = nil,
                         pressure: MemoryPressure = .normal) -> MiniMonitorFigures {
        MiniMonitorFigures(cpu: cpu, memoryUsed: cpu * 1000, memoryFraction: cpu / 2, pressure: pressure, gpu: gpu,
                           networkIn: cpu * 10, networkOut: cpu * 20, diskRead: cpu * 30, diskWrite: cpu * 40, watts: watts)
    }

    @Test func eachCornerSitsAMarginInFromItsEdges() {
        let margin = MiniMonitorPlacement.margin
        let topRight = MiniMonitorPlacement.frame(size: size, corner: .topRight, in: visible)
        #expect(topRight == CGRect(x: 1600 - margin - 220, y: 975 - margin - 160, width: 220, height: 160))
        let bottomLeft = MiniMonitorPlacement.frame(size: size, corner: .bottomLeft, in: visible)
        #expect(bottomLeft == CGRect(x: margin, y: 40 + margin, width: 220, height: 160))
        let topLeft = MiniMonitorPlacement.frame(size: size, corner: .topLeft, in: visible)
        #expect(topLeft.origin == CGPoint(x: margin, y: topRight.minY))
        let bottomRight = MiniMonitorPlacement.frame(size: size, corner: .bottomRight, in: visible)
        #expect(bottomRight.origin == CGPoint(x: topRight.minX, y: bottomLeft.minY))
    }

    @Test(arguments: ScreenCorner.allCases)
    func aPanelPlacedInACornerStaysThere(corner: ScreenCorner) {
        let frame = MiniMonitorPlacement.frame(size: size, corner: corner, in: visible)
        #expect(MiniMonitorPlacement.corner(nearest: frame, in: visible) == corner)
    }

    @Test func aDroppedPanelGoesToTheCornerOfTheQuarterItsMiddleIsIn() {
        func corner(_ x: CGFloat, _ y: CGFloat) -> ScreenCorner {
            let frame = CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
            return MiniMonitorPlacement.corner(nearest: frame, in: visible)
        }
        #expect(corner(700, 600) == .topLeft)
        #expect(corner(900, 600) == .topRight)
        #expect(corner(700, 400) == .bottomLeft)
        #expect(corner(900, 400) == .bottomRight)
        #expect(corner(-300, 2000) == .topLeft, "a panel dragged past the edge still lands in a corner")
    }

    @Test func metersKeepTheirShowingOrderWhateverOrderTheyWereSaved() {
        let meters = MiniMonitorMeters(rawValue: "power,cpu,network")
        #expect(meters?.shown == [.cpu, .network, .power])
        #expect(meters?.rawValue == "cpu,network,power")
        #expect(MiniMonitorMeters.all.rawValue == "cpu,memory,gpu,network,disk,power")
    }

    @Test func savedMetersThatNameNoneFallBackToTheDefault() {
        #expect(MiniMonitorMeters(rawValue: "") == nil)
        #expect(MiniMonitorMeters(rawValue: "fans,temperature") == nil)
        #expect(MiniMonitorMeters(rawValue: "fans,disk")?.shown == [.disk])
        #expect(MiniMonitorMeters(meters: []) == .all)
    }

    @Test func theLastMeterCannotBeTurnedOff() {
        var meters = MiniMonitorMeters(meters: [.cpu, .memory])
        meters.toggle(.cpu)
        #expect(meters.shown == [.memory])
        meters.toggle(.memory)
        #expect(meters.shown == [.memory])
        meters.toggle(.gpu)
        #expect(meters.shown == [.memory, .gpu])
    }

    @Test func halfSecondTicksAverageIntoOnePointASecond() {
        var feed = MiniMonitorFeed()
        let finished = [feed.add(figures(cpu: 0.2), interval: 0.5, step: 0.5),
                        feed.add(figures(cpu: 0.6), interval: 0.5, step: 0.5)]
        #expect(finished == [false, true])
        #expect(feed.reading.step == 1, "never a point faster than once a second")
        #expect(feed.reading.cpu.count == 1)
        #expect(abs(feed.reading.cpu[0] - 0.4) < 1e-9)
        #expect(abs((feed.reading.figures?.diskWrite ?? 0) - 16) < 1e-9)
        #expect(abs((feed.reading.figures?.memoryUsed ?? 0) - 400) < 1e-9)
    }

    @Test func secondTicksArePointsOfTheirOwn() {
        var feed = MiniMonitorFeed()
        let finished = [0.1, 0.2, 0.3].map { feed.add(figures(cpu: $0), interval: 1.02, step: 1) }
        #expect(finished == [true, true, true])
        #expect(feed.reading.cpu == [0.1, 0.2, 0.3])
        #expect(feed.reading.memory == [0.05, 0.1, 0.15])
        #expect(feed.reading.networkOut.count == 3)
    }

    @Test func aSlowerSpeedAveragesSeveralTicksIntoEachPoint() {
        var feed = MiniMonitorFeed()
        let finished = [feed.add(figures(cpu: 0.1), interval: 1, step: 2),
                        feed.add(figures(cpu: 0.3), interval: 1, step: 2)]
        #expect(finished == [false, true])
        #expect(feed.reading.step == 2)
        #expect(feed.reading.cpu.count == 1)
        #expect(abs(feed.reading.cpu[0] - 0.2) < 1e-9)
    }

    @Test func longerTicksWeighMore() {
        var feed = MiniMonitorFeed()
        let finished = [feed.add(figures(cpu: 0), interval: 1, step: 5),
                        feed.add(figures(cpu: 1), interval: 2, step: 5),
                        feed.add(figures(cpu: 1), interval: 2, step: 5)]
        #expect(finished == [false, false, true])
        #expect(abs(feed.reading.cpu[0] - 0.8) < 1e-9)
    }

    @Test func pressureIsTheLatestTicksNotAnAverage() {
        var feed = MiniMonitorFeed()
        feed.add(figures(cpu: 0.5, pressure: .critical), interval: 0.5, step: 1)
        feed.add(figures(cpu: 0.5, pressure: .warning), interval: 0.5, step: 1)
        #expect(feed.reading.figures?.pressure == .warning)
    }

    @Test func gpuAndPowerAreOnlyAveragedOverTicksThatHaveThem() {
        var feed = MiniMonitorFeed()
        feed.add(figures(cpu: 0.1, gpu: 0.4, watts: 8), interval: 0.5, step: 1)
        feed.add(figures(cpu: 0.1), interval: 0.5, step: 1)
        #expect(feed.reading.figures?.gpu == 0.4)
        #expect(feed.reading.figures?.watts == 8)
        feed.add(figures(cpu: 0.1), interval: 1, step: 1)
        #expect(feed.reading.figures?.gpu == nil)
        #expect(feed.reading.figures?.watts == nil)
        #expect(feed.reading.gpu == [0.4], "a Mac without the reading draws no graph for it")
        #expect(feed.reading.power == [8])
    }

    @Test func aSleepStartsTheGraphsAgain() {
        var feed = MiniMonitorFeed()
        feed.add(figures(cpu: 0.1), interval: 1, step: 1)
        feed.add(figures(cpu: 0.2), interval: 1, step: 1)
        let afterSleep = feed.add(figures(cpu: 0.9), interval: 600, step: 1)
        #expect(!afterSleep)
        #expect(feed.reading.cpu.isEmpty)
        #expect(feed.reading.figures == nil)
        let next = feed.add(figures(cpu: 0.3), interval: 1, step: 1)
        #expect(next)
        #expect(feed.reading.cpu == [0.3])
    }

    @Test func aNewSpeedStartsTheGraphsAgain() {
        var feed = MiniMonitorFeed()
        feed.add(figures(cpu: 0.1), interval: 1, step: 1)
        feed.add(figures(cpu: 0.2), interval: 1, step: 1)
        let firstAtNewSpeed = feed.add(figures(cpu: 0.3), interval: 1, step: 2)
        #expect(!firstAtNewSpeed)
        #expect(feed.reading.cpu.isEmpty)
        let secondAtNewSpeed = feed.add(figures(cpu: 0.5), interval: 1, step: 2)
        #expect(secondAtNewSpeed)
        #expect(abs(feed.reading.cpu[0] - 0.4) < 1e-9)
    }

    @Test func aTickWithNoIntervalIsLeftOut() {
        var feed = MiniMonitorFeed()
        let finished = [feed.add(figures(cpu: 1), interval: 0, step: 1),
                        feed.add(figures(cpu: 0.2), interval: 1, step: 1)]
        #expect(finished == [false, true])
        #expect(feed.reading.cpu == [0.2])
    }

    @Test func eachGraphHoldsAMinuteOfPoints() {
        var feed = MiniMonitorFeed()
        for index in 0..<(MiniMonitorFeed.points + 15) {
            feed.add(figures(cpu: Double(index)), interval: 1, step: 1)
        }
        #expect(feed.reading.cpu.count == MiniMonitorFeed.points)
        #expect(feed.reading.cpu.first == 15)
        #expect(feed.reading.cpu.last == Double(MiniMonitorFeed.points + 14))
    }
}
