import OTMKit
import SwiftUI

extension DiskScanSummary {
    var pickerTitle: String {
        let date = StorageChangeStyle.when(scannedAt)
        let size = Format.bytes(allocatedSize)
        guard let scheduled, scheduled.version == 1 else { return "\(date) — \(size)" }
        return "\(date) — \(size) · Scheduled · \(scheduled.cadence.title)"
    }
}

extension StorageStore {
    /// Read the last saved tree on demand, without starting a new walk.
    func showSavedScans(of scope: StorageScope) async {
        guard !isScanning else { return }
        let request = scope.request
        let scans = await Task.detached(priority: .utility) {
            let root = request.root.resolvingSymlinksInPath().path
            let key = DiskScanScope(rootPath: root, alsoEnters: request.alsoEnters.map(\.path), excludedPaths: Array(request.excludedPaths))
            return DiskScanHistory().summaries(of: key)
        }.value
        guard !isScanning, let latest = scans.first else { return }
        savedScans = scans
        selectSavedScan(latest, scope: scope)
    }

    func selectSavedScan(_ scan: DiskScanSummary, scope: StorageScope? = nil) {
        guard !isScanning else { return }
        applySavedScan(scan, scope: scope ?? self.scope)
    }
}

struct StorageSavedScanPicker: View {
    let store: StorageStore

    var body: some View {
        if let summary = store.summary, !store.savedScans.isEmpty {
            HStack(spacing: 10) {
                Picker("Scan", selection: Binding(get: { summary.scannedAt }, set: { date in
                    if let scan = store.savedScans.first(where: { $0.scannedAt == date }) { store.selectSavedScan(scan) }
                })) {
                    ForEach(store.savedScans, id: \.scannedAt) { scan in
                        StorageScanChoice(scan: scan).tag(scan.scannedAt)
                    }
                }
                .disabled(store.isScanning)
                if store.showingSavedScan {
                    Text("Saved summary · largest folders only")
                        .font(.metadata).foregroundStyle(.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct StorageScanChoice: View {
    let scan: DiskScanSummary

    var body: some View {
        if scan.scheduled?.version == 1 {
            Label(scan.pickerTitle, systemImage: "clock")
        } else {
            Text(scan.pickerTitle)
        }
    }
}
