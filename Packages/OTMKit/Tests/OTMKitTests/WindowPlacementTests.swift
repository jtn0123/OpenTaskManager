import Foundation
@testable import OTMKit
import Testing

struct WindowPlacementTests {
    /// A 1600 by 1000 point screen under a 30-point menu bar, as in the VM.
    private let vm = CGRect(x: 0, y: 0, width: 1600, height: 970)

    @Test(arguments: [
        // Screen's usable area → the default size: a share of it, within the minimum and maximum.
        (CGSize(width: 1600, height: 970), CGSize(width: 1200, height: 776)),
        (CGSize(width: 1728, height: 1047), CGSize(width: 1296, height: 838)),
        (CGSize(width: 2560, height: 1415), CGSize(width: 1440, height: 940)),
        (CGSize(width: 1280, height: 775), CGSize(width: 1180, height: 760)),
        // A screen smaller than the default minimum: the screen, down to the window's minimum.
        (CGSize(width: 1024, height: 743), CGSize(width: 1024, height: 743)),
        (CGSize(width: 800, height: 450), CGSize(width: 820, height: 480)),
    ])
    func defaultSizeIsAShareOfTheScreen(screen: CGSize, size: CGSize) {
        #expect(WindowPlacement.defaultFrame(in: CGRect(origin: .zero, size: screen)).size == size)
    }

    @Test func defaultIsCentredAcrossAndALittleAboveTheMiddle() {
        let frame = WindowPlacement.defaultFrame(in: vm)
        #expect(frame == CGRect(x: 200, y: 129, width: 1200, height: 776))
        // A third of the spare height above, two thirds below.
        #expect(vm.maxY - frame.maxY == 65)
        #expect(frame.minY - vm.minY == 129)
        // On a second screen to the left of and above the main one.
        let side = CGRect(x: -1920, y: 300, width: 1920, height: 1055)
        let onSide = WindowPlacement.defaultFrame(in: side)
        #expect(side.contains(onSide))
        #expect(onSide.midX == side.midX)
    }

    @Test func nothingSavedOpensAtTheDefault() {
        #expect(WindowPlacement.openingFrame(saved: nil, screens: [vm], main: vm) == WindowPlacement.defaultFrame(in: vm))
        let empty = CGRect(x: 10, y: 10, width: 0, height: 600)
        #expect(WindowPlacement.openingFrame(saved: empty, screens: [vm], main: vm) == WindowPlacement.defaultFrame(in: vm))
    }

    @Test func aSavedFrameOnScreenComesBackAsItWas() {
        let narrow = CGRect(x: 210, y: 148, width: 820, height: 760)
        #expect(WindowPlacement.openingFrame(saved: narrow, screens: [vm], main: vm) == narrow)
        let large = CGRect(x: 0, y: 0, width: 1600, height: 970)
        #expect(WindowPlacement.openingFrame(saved: large, screens: [vm], main: vm) == large)
    }

    @Test func aSavedFrameGoesBackToTheScreenItMostlyCovers() {
        let side = CGRect(x: 1600, y: 0, width: 2560, height: 1415)
        let saved = CGRect(x: 1500, y: 200, width: 1300, height: 800)
        let frame = WindowPlacement.openingFrame(saved: saved, screens: [vm, side], main: vm)
        // Most of it was on the second screen, so it's moved just onto that one.
        #expect(frame == CGRect(x: 1600, y: 200, width: 1300, height: 800))
    }

    @Test func aFrameFromAScreenThatsGoneOpensInTheMiddleOfTheMainOne() {
        let saved = CGRect(x: 1700, y: 100, width: 1000, height: 700)
        let frame = WindowPlacement.openingFrame(saved: saved, screens: [vm], main: vm)
        #expect(frame.size == saved.size)
        #expect(frame.midX == vm.midX)
        #expect(vm.contains(frame))
    }

    @Test func aFrameTooBigForItsScreenShrinksAndMovesOnToIt() {
        let saved = CGRect(x: -100, y: 500, width: 2000, height: 1200)
        let frame = WindowPlacement.openingFrame(saved: saved, screens: [vm], main: vm)
        #expect(frame == vm)
    }

    @Test func aFrameHangingOffTheTopComesDownSoItsTitleBarShows() {
        let saved = CGRect(x: 300, y: 600, width: 1000, height: 700)
        let frame = WindowPlacement.openingFrame(saved: saved, screens: [vm], main: vm)
        #expect(frame == CGRect(x: 300, y: 270, width: 1000, height: 700))
        #expect(frame.maxY == vm.maxY)
    }

    @Test func aFrameNeverOpensBelowTheMinimumSize() {
        let saved = CGRect(x: 100, y: 100, width: 300, height: 200)
        let frame = WindowPlacement.openingFrame(saved: saved, screens: [vm], main: vm)
        #expect(frame.size == WindowPlacement.minimumSize)
    }

    @Test func framesSaveAsWholePointsAndReadBack() {
        let frame = CGRect(x: -40.4, y: 12.6, width: 1180.5, height: 760)
        #expect(WindowPlacement.string(frame) == "-40 13 1181 760")
        #expect(WindowPlacement.frame(from: "-40 13 1181 760") == CGRect(x: -40, y: 13, width: 1181, height: 760))
        // AppKit's own frame strings start with the same four numbers.
        #expect(WindowPlacement.frame(from: "210 148 820 760 0 0 1600 970 ") == CGRect(x: 210, y: 148, width: 820, height: 760))
    }

    @Test(arguments: [nil, "", "210 148 820", "210 148 wide 760", "210 148 0 760", "210 148 820 -5", "nan 0 820 760", "0 0 inf 760"])
    func unreadableFramesAreIgnored(text: String?) {
        #expect(WindowPlacement.frame(from: text) == nil)
    }
}
