import OTMKit
import Testing

@MainActor
struct SamplingDemandStoreTests {
    nonisolated private static let sources: [SamplingDemand.Source] = [.sensors, .restrictedProcesses, .users, .sensorTable, .menuBarIcon]

    @Test(arguments: sources)
    func overlappingConsumersReleaseOnlyTheirOwnCount(source: SamplingDemand.Source) {
        let store = SamplingDemandStore()
        #expect(!store.contains(source))
        store.add(source)
        store.add(source)
        store.remove(source)
        #expect(store.contains(source))
        store.remove(source)
        #expect(!store.contains(source))
        store.remove(source)
        store.add(source)
        #expect(store.contains(source))
        store.remove(source)
        #expect(!store.contains(source))
    }

    @Test func sourcesAndStoreInstancesStayIndependent() {
        let first = SamplingDemandStore()
        let second = SamplingDemandStore()
        for source in Self.sources { first.add(source) }
        first.remove(.sensors)
        #expect(!first.contains(.sensors))
        for source in Self.sources {
            #expect(first.contains(source) == (source != .sensors))
            #expect(!second.contains(source))
        }
    }
}
