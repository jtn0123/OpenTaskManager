import Foundation
import OTMKit

/// Reads stored lifetimes without walking sockets, migrating or changing the app's recorder.
func connectionsCommand(_ options: Options) async {
    guard options.positional.first == "history" else {
        fail("usage: otm connections history [TEXT] [--since 1h|24h|7d] [--json]")
    }
    let since = options.since ?? "24h"
    guard ["1h", "24h", "7d"].contains(since), let range = HistoryRangeOption(since) else {
        fail("--since takes 1h, 24h or 7d")
    }
    let search = options.positional.dropFirst().joined(separator: " ")
    let end = Date.now
    let start = end.addingTimeInterval(-range.seconds)
    do {
        let recorder = try FlightRecorder(reading: FlightRecorder.defaultURL)
        guard try await recorder.keepsConnectionHistory() else {
            fail("no socket history yet: run this version of OpenTaskManager and visit Connections")
        }
        let result = try await recorder.connectionHistoryResult(matching: search, from: start, to: end)
        let rows = result.lifetimes
        let coverage = result.coverage
        if options.json {
            printJSON(result)
        } else {
            print(coverage.summary)
            print(coverage.watchedWords)
            for row in rows {
                let connection = row.socket.connection
                print("\n\(row.process.name) · PID \(connection.pid) · \(connection.transport.rawValue)")
                if let path = row.process.path { print(path) }
                print("\(connection.local.formatted) → \(connection.remote?.formatted ?? "—")")
                print("First seen \(stamp(row.socket.firstSeen)) · last seen \(stamp(row.socket.lastSeen))")
                print(row.endedWords(time: stamp))
            }
            if rows.isEmpty { print("No stored lifetimes match. Unwatched stretches are not evidence of no connection.") }
        }
    } catch {
        fail("couldn't read socket history: \(error.localizedDescription)")
    }
}

private func stamp(_ date: Date) -> String { date.formatted(.dateTime.year().month().day().hour().minute().second()) }
