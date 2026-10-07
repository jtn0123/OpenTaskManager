import Dispatch
import os

/// Runs blocking work (file system walks, Security framework calls) on a
/// few threads at once, so a long list finishes sooner without flooding the
/// disk or taking every core.
public enum BoundedWork {
    /// Calls `body` for each item on up to `width` threads and returns once
    /// all are done, or once `isCancelled` says to stop (items not yet
    /// started are then skipped). Blocks the calling thread.
    public static func forEach<Item: Sendable>(_ items: [Item], width: Int,
                                               isCancelled: @Sendable () -> Bool = { false },
                                               _ body: @Sendable (Item) -> Void) {
        guard !items.isEmpty else { return }
        let next = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: max(1, min(width, items.count))) { _ in
            while !isCancelled() {
                let index = next.withLock { value in
                    defer { value += 1 }
                    return value
                }
                guard index < items.count else { return }
                body(items[index])
            }
        }
    }

    /// Transforms each item on up to `width` threads, keeping the order.
    public static func map<Item: Sendable, Result: Sendable>(_ items: [Item], width: Int,
                                                             _ transform: @Sendable (Item) -> Result) -> [Result] {
        let results = OSAllocatedUnfairLock(initialState: [Int: Result]())
        forEach(Array(items.indices), width: width) { index in
            let result = transform(items[index])
            results.withLock { $0[index] = result }
        }
        let done = results.withLock { $0 }
        return items.indices.compactMap { done[$0] }
    }
}

/// A flag one side sets and many threads read, for stopping `BoundedWork`.
public final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isSet: Bool { state.withLock { $0 } }

    public func set() {
        state.withLock { $0 = true }
    }
}
