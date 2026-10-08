import OTMKit

extension AppModel {
    func sampleConnectionHistory(processes: [ProcessSample]) {
        ConnectionStore.shared.sampleBackground(model: self, processes: processes)
    }
}
