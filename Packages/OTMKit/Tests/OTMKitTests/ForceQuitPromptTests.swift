@testable import OTMKit
import Testing

struct ForceQuitPromptTests {
    @Test func oneTargetIsNamedInTheTitle() {
        #expect(ForceQuitPrompt.title(names: ["Safari"]) == "Force quit Safari?")
        #expect(ForceQuitPrompt.message(names: ["Safari"])
            == "It stops at once, and any unsaved work in it is lost. End Task asks it to quit instead, so it can save first.")
    }

    @Test func severalAreCountedInTheTitleAndNamedInTheMessage() {
        let names = ["Safari", "Mail", "sleep"]
        #expect(ForceQuitPrompt.title(names: names) == "Force quit 3 processes?")
        #expect(ForceQuitPrompt.message(names: names) == "Safari, Mail and sleep stop at once, and any unsaved work in "
            + "them is lost. End Task asks them to quit instead, so they can save first.")
        #expect(ForceQuitPrompt.list(["Safari", "Mail"]) == "Safari and Mail")
    }

    @Test func pastFiveNamesTheRestAreCounted() {
        let five = ["a", "b", "c", "d", "e"]
        #expect(ForceQuitPrompt.list(five) == "a, b, c, d and e")
        #expect(ForceQuitPrompt.list(five + ["f", "g", "h"]) == "a, b, c, d, e and 3 more")
    }
}
