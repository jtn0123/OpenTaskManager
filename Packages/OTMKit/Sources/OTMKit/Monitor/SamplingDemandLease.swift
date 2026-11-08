/// One view's share of a source. Repeated layout and visibility notices
/// must not add another count, and stopping twice must not release someone else's.
public struct SamplingDemandLease: Sendable {
    public enum Change: Sendable, Equatable {
        case add, remove
    }

    private var counted = false

    public init() {}

    public mutating func update(
        enabled: Bool, windowVisible: Bool, miniaturized: Bool, hidden: Bool, hasVisibleRoom: Bool
    ) -> Change? {
        setCounted(enabled && windowVisible && !miniaturized && !hidden && hasVisibleRoom)
    }

    public mutating func release() -> Change? { setCounted(false) }

    private mutating func setCounted(_ next: Bool) -> Change? {
        guard next != counted else { return nil }
        counted = next
        return next ? .add : .remove
    }
}
