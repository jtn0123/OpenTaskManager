import Foundation
import Observation
import OTMKit
import os
import Testing

@MainActor
struct DiskActivityStoreTests {
    private func disk(read: Int, write: Int) throws -> DiskSample {
        let json = """
        {"bsdName":"disk0","name":"Macintosh HD","readBytesPerSecond":\(read),"writeBytesPerSecond":\(write),
         "readOperationsPerSecond":0,"writeOperationsPerSecond":0,"totalRead":100,"totalWritten":200,"activeFraction":0}
        """
        return try JSONDecoder().decode(DiskSample.self, from: Data(json.utf8))
    }

    @Test func disabledDoesNotEvaluateSamplesAndLiveSettingsPauseAndSleepWork() throws {
        let name = "OTM-DiskLightTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DiskActivityStore(defaults: defaults)
        var evaluated = false
        func samples() -> [DiskSample] { evaluated = true; return [] }
        store.update(samples(), visible: true)
        #expect(!evaluated && store.lights.isEmpty)
        Settings.diskActivityLights.set(true, in: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        let reading = try disk(read: 10, write: 0)
        let writing = try disk(read: 0, write: 10)
        store.update([reading], visible: true)
        #expect(store.lights.first?.reading == true && store.lights.first?.writing == false)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = store.lights } onChange: { changes.withLock { $0 += 1 } }
        let sameState = try disk(read: 100, write: 0)
        store.update([sameState], visible: true)
        #expect(changes.withLock { $0 } == 0)
        let visible = store.lights
        store.update([writing], visible: false)
        #expect(store.lights == visible)
        store.update([writing], visible: true)
        #expect(store.lights.first?.writing == true && store.lights.first?.reading == false)
        store.setPaused(true)
        #expect(store.lights.first?.writing == false)
        Settings.diskLightSelection.set(.init(rawValue: ""), in: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(store.lights.isEmpty)
        Settings.diskActivityLights.set(false, in: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(!store.enabled && store.lights.isEmpty)
    }
}
