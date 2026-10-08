import OTMKit
import SwiftUI

extension Page {
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle"
        case .performance: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .startup: "sunrise"
        case .apps: "square.grid.3x3"
        case .users: "person.2"
        case .system: "info.circle"
        case .drivers: "puzzlepiece.extension"
        case .storage: "internaldrive"
        }
    }

    /// ⌘1 to ⌘9 for the first nine pages, in the View menu and the page menu.
    var shortcut: KeyboardShortcut? {
        guard let number = shortcutNumber else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(number)")))
    }
}
