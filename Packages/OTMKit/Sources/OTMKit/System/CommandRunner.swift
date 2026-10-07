import Darwin
import Foundation
import os

/// Runs a system tool and returns what it printed, giving up after a timeout.
/// Every tool the app runs goes through here: a tool that hangs would
/// otherwise hold up whatever was waiting for it, such as the sampler.
enum CommandRunner {
    /// Which of the tool's streams to keep; the others are discarded.
    enum Capture {
        case output, errors, both
    }

    /// What a tool printed and how it exited.
    struct Result {
        var status: Int32
        var text: String
    }

    /// Runs a tool to completion. Nil when it couldn't start, was killed by a
    /// signal, was stopped through `stopper`, or ran past `timeout` seconds
    /// (it's then terminated). Blocks the calling thread; see `output(of:_:timeout:)`.
    static func execute(_ executable: String, _ arguments: [String], capture: Capture = .both, timeout: TimeInterval,
                        stopper: Stopper? = nil) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = capture == .errors ? FileHandle.nullDevice : pipe
        process.standardError = capture == .output ? FileHandle.nullDevice : pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        stopper?.attach(process)
        defer { stopper?.detach() }

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
        return Result(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    /// Standard output and error together, whatever the exit status, or nil
    /// as for `execute`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        execute(executable, arguments, timeout: timeout)?.text
    }

    /// `run` on a background queue, so waiting doesn't tie up a Swift concurrency thread.
    static func output(of executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable, arguments, timeout: timeout))
            }
        }
    }

    /// `execute` on a background queue for a long-running tool the user can
    /// stop: cancelling the calling task terminates it, and the result is then nil.
    static func cancellableExecute(_ executable: String, _ arguments: [String], capture: Capture = .both,
                                   timeout: TimeInterval) async -> Result? {
        let stopper = Stopper()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: execute(executable, arguments, capture: capture, timeout: timeout, stopper: stopper))
                }
            }
        } onCancel: {
            stopper.stop()
        }
    }

    /// Stops a running tool from another thread. A stop that comes before
    /// the tool starts takes effect as soon as it does.
    final class Stopper: Sendable {
        private struct State {
            var process: Process?
            var stopped = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func attach(_ process: Process) {
            let stopped = state.withLock { state in
                state.process = process
                return state.stopped
            }
            if stopped { Self.halt(process) }
        }

        func detach() {
            state.withLock { $0.process = nil }
        }

        func stop() {
            let process = state.withLock { state in
                state.stopped = true
                return state.process
            }
            if let process { Self.halt(process) }
        }

        /// Asks the tool to quit, then insists a second later, as at a timeout.
        private static func halt(_ process: Process) {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
