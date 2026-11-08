import OTMKit
import SwiftUI
import Testing

struct PagePresentationTests {
    @Test(arguments: Page.allCases)
    func shortcutsMatchTheViewMenusCommandNumbers(page: Page) {
        if let number = page.shortcutNumber {
            #expect(page.shortcut?.key == KeyEquivalent(Character("\(number)")))
            #expect(page.shortcut?.modifiers == .command)
        } else {
            #expect(page.shortcut == nil)
        }
    }

    @Test func eachPageHasItsOwnSymbol() {
        #expect(Page.allCases.allSatisfy { !$0.symbol.isEmpty })
        #expect(Set(Page.allCases.map(\.symbol)).count == Page.allCases.count)
    }
}
