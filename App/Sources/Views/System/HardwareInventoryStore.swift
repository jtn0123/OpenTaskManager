import Foundation
import Observation
import OTMKit

/// The System page's slower hardware report: memory type and maker, storage
/// controllers and their drives, SD card readers and smart cards, from one
/// `system_profiler` run (`HardwareInventoryReader`). None of it changes
/// while the Mac runs, short of plugging in a reader, so it's read the first
/// time the page opens and kept for the session; Refresh reads it again.
@Observable
@MainActor
final class HardwareInventoryStore {
    static let shared = HardwareInventoryStore()

    private(set) var inventory: HardwareInventory?
    /// When it was read, for a saved report.
    private(set) var readAt: Date?
    private(set) var isReading = false

    /// Reads it once a session.
    func load() async {
        if inventory == nil { await read() }
    }

    /// Runs the report on a background queue, so waiting for it doesn't hold
    /// up a Swift concurrency thread.
    func read() async {
        guard !isReading else { return }
        isReading = true
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: HardwareInventoryReader.read())
            }
        }
        inventory = result
        readAt = Date()
        isReading = false
    }
}
