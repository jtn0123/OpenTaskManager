@testable import OTMKit
import Testing

struct PathPreviewTests {
    @Test func shortPathsAndRootNeedNoCut() {
        #expect(PathParts("/bin/launchctl").compactFolder() == "/bin")
        #expect(PathParts("/launchctl").compactFolder() == "/")
        #expect(PathParts("launchctl").compactFolder() == nil)
        #expect(PathParts("/").compactFolder() == nil)
        #expect(PathParts("/abcdef/file").compactFolder(maxCharacters: 7) == "/abcdef")
    }

    @Test func aLongFolderKeepsBothEndsAndTheNameStaysWhole() {
        let path = "/Applications/Very Long Application Name.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"
        let parts = PathParts(path)
        let preview = parts.compactFolder(maxCharacters: 32)
        #expect(parts.name == "Helper")
        #expect(parts.folder == String(path.dropLast("/Helper".count)))
        #expect(preview == "/Applications/Ve…/Contents/MacOS")
        #expect(preview?.count == 32)
        #expect(parts.compactFolder(maxCharacters: 0) == "…")
        #expect(parts.compactFolder(maxCharacters: 1) == "…")
        #expect(parts.compactFolder(maxCharacters: 2) == "/…")
    }

    @Test func cutsOnlyBetweenWholeCharactersAndDoesNotAlterTheOriginal() {
        let folder = "/👩🏽‍💻/Cafe\u{301}/日本語/long-folder/📁"
        let parts = PathParts(folder + "/file")
        let preview = parts.compactFolder(maxCharacters: 9)
        #expect(preview == String(folder.prefix(4)) + "…" + String(folder.suffix(4)))
        #expect(preview?.count == 9)
        #expect(parts.folder == folder)
        #expect(PathParts(folder + "/file///").compactFolder(maxCharacters: 9) == preview)
    }
}
