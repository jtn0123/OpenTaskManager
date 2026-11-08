/// One user's CPU (100 = one core) and summed process memory over time.
public struct UserHistory: Sendable {
    public private(set) var cpu: History<Double>
    public private(set) var memory: History<Double>

    public init(capacity: Int) {
        cpu = History(capacity: capacity)
        memory = History(capacity: capacity)
    }

    public mutating func append(_ totals: UsageTotals) {
        cpu.append(totals.cpuPercent)
        memory.append(Double(totals.memory))
    }
}
