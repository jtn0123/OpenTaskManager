import Foundation
import OTMKit

extension HistoryRecordingStore {
    /// Opens live History around a stored observation, with that moment pinned once the records load.
    func showConnectionMoment(_ time: Date) {
        close()
        connectionMoment = time
        Settings.historyRange.set(.hour)
        Settings.historyFitsRecording.set(false)
        PageSelection.shared.page = .history
    }
}
