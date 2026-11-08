import AppKit
import OTMKit

/// Shared by the context menu and the detail pane.
@MainActor
enum StartupActions {
    static func reveal(_ item: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
    }

    static func openPlist(_ item: LaunchItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.plistPath))
    }

    static func copyLabel(_ item: LaunchItem) {
        copy(item.label)
    }

    /// The property list's path, the file Reveal in Finder shows.
    static func copyPath(_ item: LaunchItem) {
        copy(item.plistPath)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
