import Foundation
import OTMKit

func ownerCommand(_ options: Options) {
    guard options.positional.count == 1, let query = options.positional.first else {
        fail("owner needs a path or local port (8080, :8080, tcp:8080 or udp:5353)")
    }
    do {
        let result = try OwnerLookup.search(query)
        if options.json {
            printJSON(result)
            return
        }
        if result.processes.isEmpty { print(result.emptyDescription) }
        for process in result.processes {
            print("\(process.name) · PID \(process.identity.pid) · \(process.user)")
            if let path = process.path { print("  \(path)") }
            for match in process.matches { print("  \(match.label)") }
        }
        print(result.unreadableDescription)
        print("Checked \(result.checkedProcesses) of \(result.totalProcesses) processes in "
            + Format.fixed(result.duration * 1_000, 1) + " ms")
        if let note = result.target.volumeNote { print(note) }
    } catch {
        fail(error.localizedDescription)
    }
}
