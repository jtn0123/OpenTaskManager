/// Fixed-capacity ring buffer for graph history. Appending past capacity
/// drops the oldest value.
public struct History<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "History capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Adds `value` as the newest, returning the oldest when it's dropped to
    /// make room, so running totals over the window can let it go.
    @discardableResult
    public mutating func append(_ value: Element) -> Element? {
        if storage.count < capacity {
            storage.append(value)
            return nil
        }
        let dropped = storage[head]
        storage[head] = value
        head = (head + 1) % capacity
        return dropped
    }

    /// Values from oldest to newest.
    public var values: [Element] {
        guard storage.count == capacity, head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    /// Adds each value, through `figure`, to `sums`, aligned on the newest,
    /// which goes into the last element; values older than `sums` has room
    /// for are left out. Sums many histories without building each one's
    /// `values` first.
    public func addValues(to sums: inout [Double], _ figure: (Element) -> Double) {
        let count = min(storage.count, sums.count)
        guard count > 0 else { return }
        var index = (head + storage.count - count) % storage.count
        for slot in sums.count - count..<sums.count {
            sums[slot] += figure(storage[index])
            index = index + 1 == storage.count ? 0 : index + 1
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// The sum of a window's values, kept as they come in and leave, so it
/// costs one addition a sample rather than a walk over the window. It's
/// exactly zero once the window holds only zeros, which adding and taking
/// away the same values in floating point doesn't promise by itself: an
/// idle process never ranks above another for a rounding trace.
public struct RunningSum: Sendable, Equatable {
    private var total = 0.0
    /// Values in the window that aren't zero.
    private var nonzero = 0

    public init() {}

    public var value: Double { nonzero == 0 ? 0 : total }

    /// Counts `value` in as it enters the window.
    public mutating func add(_ value: Double) { change(by: value, count: 1) }

    /// Takes `value` out as it leaves the window.
    public mutating func remove(_ value: Double) { change(by: -value, count: -1) }

    private mutating func change(by amount: Double, count: Int) {
        guard amount != 0 else { return }
        nonzero += count
        total = nonzero == 0 ? 0 : total + amount
    }
}
