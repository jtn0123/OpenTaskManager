import Foundation

/// The app supplies Finder's recycler; tests supply a fake that leaves every file in place.
@MainActor
public protocol StorageCleanupRecycler {
    func recycle(_ path: String) async -> RemovalResult
}

public struct StorageCleanupMeasurement: Sendable, Identifiable {
    public var id: String { volume }
    public let volume: String
    public let before: Int64?
    public let after: Int64?

    public var text: String { StorageCleanupText.capacityChange(before: before, after: after) }
}

public struct StorageCleanupExecution: Sendable {
    public let outcomes: [RemovalOutcome]
    public let measurements: [StorageCleanupMeasurement]

    /// Rechecks each path immediately before asking the recycler to move it. Capacity is an independent observation.
    @MainActor
    public static func run(_ items: [StorageCleanupItem], selection: Set<String>, home: String,
                           recycler: any StorageCleanupRecycler) async -> StorageCleanupExecution {
        let picked = items.filter { selection.contains($0.id) }
        let volumes = Set(picked.compactMap(\.state.volumePath)).sorted()
        let before = await Task.detached(priority: .userInitiated) {
            volumes.map { StorageCleanupMeasurement(volume: $0, before: StorageCleanupReader.availableCapacity($0), after: nil) }
        }.value
        var outcomes: [RemovalOutcome] = []
        for item in picked {
            let result: RemovalResult
            if let refusal = item.refusal {
                result = .failed(refusal)
            } else {
                let now = await Task.detached(priority: .userInitiated) { StorageCleanupReader.read(item.id, home: home) }.value
                if let failure = StorageCleanupRules.revalidationFailure(item, now: now, home: home) {
                    result = .failed(failure)
                } else {
                    result = await recycler.recycle(item.id)
                }
            }
            outcomes.append(RemovalOutcome(path: item.id, result: result))
        }
        let measured = await Task.detached(priority: .userInitiated) {
            before.map {
                StorageCleanupMeasurement(volume: $0.volume, before: $0.before, after: StorageCleanupReader.availableCapacity($0.volume))
            }
        }.value
        return StorageCleanupExecution(outcomes: outcomes, measurements: measured)
    }
}
