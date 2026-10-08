import Foundation
import SQLite3
import Testing
@testable import OTMKit

struct ListenerRecorderTests {
    private let time = Date(timeIntervalSince1970: 1_000)

    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    private func listener(port: Int) -> ListenerObservation {
        let executable = ListenerExecutable(path: "/example/server", teamIdentifier: "TEAM", signingIdentifier: "example.server")
        let identity = ListenerIdentity(executable: executable, transport: .tcp, port: port, scope: .loopback)
        let connection = Connection(id: .init(pid: 7, fd: 3, socket: UInt64(port)), processName: "server", transport: .tcp,
                                    family: .ipv4, local: Endpoint(address: "127.0.0.1", port: port), remote: nil, tcpState: .listen)
        return ListenerObservation(identity: identity, connection: connection)
    }

    @Test func baselineAndPendingChangesRoundTripAndAcceptAcrossRecorders() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originals = (1...450).map { listener(port: $0) }
        let added = listener(port: 8_080)
        let other = listener(port: 9_090)
        do {
            let recorder = try FlightRecorder(url: url)
            #expect(try await recorder.listenerReview() == nil)
            let initial = try await recorder.observeListeners(originals, confirmed: [], at: time)
            #expect(initial.review.baseline.listeners.count == 450)
            #expect(initial.review.changes.isEmpty)
            #expect(initial.newChanges == 0)
            let changes = try await recorder.observeListeners([added, other], confirmed: [added, other], at: time.addingTimeInterval(3))
            #expect(changes.newChanges == 2)
        }
        let reader = try FlightRecorder(reading: url)
        let saved = try #require(try await reader.listenerReview())
        #expect(saved.baseline.listeners == Set(originals.map(\.identity)))
        #expect(saved.changes.map(\.id) == [added.identity, other.identity])
        #expect(saved.changes.first?.listener.connection == added.connection)
        let recorder = try FlightRecorder(url: url)
        _ = try await recorder.acceptListeners([added.identity], at: time.addingTimeInterval(6))
        // A later walk merges with acceptance from another writer, rather than putting the old pending row back.
        let another = try FlightRecorder(url: url)
        let latest = try await another.observeListeners([added, other], confirmed: [added, other], at: time.addingTimeInterval(9))
        #expect(latest.review.changes.map(\.id) == [other.identity])
        #expect(latest.newChanges == 0)
        #expect(latest.review.baseline.listeners.contains(added.identity))
        let accepted = try #require(try await another.acceptListeners(Set(latest.review.changes.map(\.id)), at: time.addingTimeInterval(12)))
        #expect(accepted.changes.isEmpty)
        #expect(accepted.baseline.listeners.count == 452)
        #expect(try await reader.listenerReview() == accepted)
        try await recorder.prune(before: time.addingTimeInterval(20_000))
        #expect(try await reader.listenerReview() == accepted)
    }

    @Test func migrationFromSevenKeepsExistingHistoryAndReadOnlyReaderDoesNotMigrate() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let event = HistoryEvent(time: time, kind: .appLaunched, name: "Example")
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append([event])
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP TABLE listener_review; PRAGMA user_version = 7", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let oldReader = try FlightRecorder(reading: url)
        #expect(try await oldReader.listenerReview() == nil)
        #expect(try await oldReader.schemaVersionOnDisk() == 7)
        let migrated = try FlightRecorder(url: url)
        #expect(try await migrated.schemaVersionOnDisk() == 10)
        #expect(try await migrated.listenerReview() == nil)
        #expect(try await migrated.events(from: time, to: time.addingTimeInterval(1)) == [event])
        let initial = try await migrated.observeListeners([listener(port: 8_080)], confirmed: [], at: time)
        #expect(try await oldReader.listenerReview() == initial.review)
        #expect(try await FlightRecorder(url: url).listenerReview() == initial.review)
    }
}
