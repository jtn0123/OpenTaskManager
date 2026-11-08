import Dispatch
import os

/// Holds a benchmark's own thread at one of its progress reports until the
/// test lets it go, so a cancel lands at a known point in the run rather than
/// wherever a fixed sleep happens to end on a loaded Mac.
final class ProgressGate: Sendable {
    private struct Count {
        /// Reports with a fraction above 0, the run's start left out.
        var pastStart = 0
        var held = false
        var afterHold = 0
    }

    private let holdAt: Int
    private let count = OSAllocatedUnfairLock(initialState: Count())
    private let reached: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)

    /// Holds the run at its `report`th report past the start: 1 is a
    /// benchmark's first warm-up done, 2 its first timed repeat.
    init(holdingAt report: Int) {
        holdAt = report
        (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// The progress closure's body, on the benchmark's thread: at the gate it
    /// waits there until `open()`.
    func report(fraction: Double) {
        let holds = count.withLock { count in
            if count.held {
                count.afterHold += 1
                return false
            }
            if fraction > 0 { count.pastStart += 1 }
            count.held = count.pastStart == holdAt
            return count.held
        }
        guard holds else { return }
        reachedContinuation.yield()
        release.wait()
    }

    /// Waits for the run to reach the gate: false if it ended first.
    func waitUntilHeld() async -> Bool {
        for await _ in reached { return true }
        return false
    }

    /// Lets the held run carry on.
    func open() {
        release.signal()
    }

    /// The run ended, so a test still waiting for the gate stops waiting.
    func runEnded() {
        reachedContinuation.finish()
    }

    /// Reports the run made after the one it was held at.
    var reportsAfterHold: Int { count.withLock { $0.afterHold } }
}
