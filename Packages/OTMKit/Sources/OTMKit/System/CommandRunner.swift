import Darwin
import Foundation

/// Runs a system tool and returns what it printed, giving up after a timeout.
enum CommandRunner {
    /// Standard output and error together, or nil when the tool couldn't
    /// start, was killed by a signal, or ran past `timeout` seconds (it's
    /// then terminated). Blocks the calling thread; see `output(of:_:timeout:)`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Ask politely at the deadline, then insist a second later. A
        // stopped tool closes its end of the pipe, which ends the read below.
        // Both are cancelled once it exits, and check first in case it just did.
        let terminate = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let forceKill = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: terminate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 1, execute: forceKill)

        // Read before waiting so a chatty tool can't fill the pipe and stall.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        terminate.cancel()
        forceKill.cancel()
        guard process.terminationReason == .exit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `run` on a background queue, so waiting doesn't tie up a Swift concurrency thread.
    static func output(of executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable, arguments, timeout: timeout))
            }
        }
    }
}

/// Reads System Integrity Protection, FileVault and Gatekeeper state from
/// their command-line tools. None of the three needs administrator rights.
public enum SecurityReader {
    public static func read(timeout: TimeInterval = 3) async -> SecurityStatus {
        async let sip = CommandRunner.output(of: "/usr/bin/csrutil", ["status"], timeout: timeout)
        async let fileVault = CommandRunner.output(of: "/usr/bin/fdesetup", ["status"], timeout: timeout)
        async let gatekeeper = CommandRunner.output(of: "/usr/sbin/spctl", ["--status"], timeout: timeout)
        return SecurityStatus(
            sip: await sip.flatMap(SystemFacts.parseSIP),
            fileVault: await fileVault.flatMap(SystemFacts.parseFileVault),
            gatekeeper: await gatekeeper.flatMap(SystemFacts.parseGatekeeper)
        )
    }
}
