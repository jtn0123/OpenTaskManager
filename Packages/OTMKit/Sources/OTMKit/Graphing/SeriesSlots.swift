import Foundation

/// Which of the palette's series colours each app in a "by app" graph gets.
///
/// The graphs rank apps by their latest figures, so the order changes
/// often; colouring by rank would give an app a new colour each time it
/// passed another. Here an app keeps its slot for as long as it stays in the
/// graph, and a newcomer takes the slot it was first given this session
/// (`SeriesHomes`, shared by every graph, so an app tends to keep one colour
/// across them) if no app in the graph has it, or else the first free one.
/// The first apps a session sees get slots in rank order, as before.
public struct SeriesSlots<ID: Hashable & Sendable>: Sendable {
    /// How many colours there are.
    public let count: Int
    /// The slot each app in the graph had at the last call.
    private var held: [ID: Int] = [:]
    /// The last call's apps and answer, returned again while they're the same.
    private var lastIDs: [ID] = []
    private var lastSlots: [Int] = []

    public init(count: Int) {
        self.count = max(count, 1)
    }

    /// A slot in `0..<count` for each of `ids`, in order: different slots for
    /// the first `count` apps; any after them take their home slots, repeats.
    public mutating func assign(_ ids: [ID], homes: inout SeriesHomes<ID>) -> [Int] {
        if ids == lastIDs { return lastSlots }
        let distinct = min(ids.count, count)
        var slots = [Int?](repeating: nil, count: ids.count)
        var taken = Set<Int>()
        // Apps already in the graph keep their slots.
        for index in 0..<distinct {
            if let slot = held[ids[index]], !taken.contains(slot) {
                slots[index] = slot
                taken.insert(slot)
            }
        }
        for index in 0..<ids.count where slots[index] == nil {
            let home = homes.slot(for: ids[index], count: count)
            guard index < distinct else {
                slots[index] = home
                continue
            }
            let slot = !taken.contains(home) ? home : (0..<count).first { !taken.contains($0) } ?? home
            slots[index] = slot
            taken.insert(slot)
        }
        let assigned = slots.map { $0 ?? 0 }
        held = [:]
        for (id, slot) in zip(ids, assigned) where held[id] == nil {
            held[id] = slot
        }
        lastIDs = ids
        lastSlots = assigned
        return assigned
    }
}

/// The slot each app was first given this session, in the order apps were
/// first seen, shared by every "by app" graph. Forgets them all past `limit`
/// apps, so a long session of short-lived processes can't grow it for ever.
public struct SeriesHomes<ID: Hashable & Sendable>: Sendable {
    public let limit: Int
    private var homes: [ID: Int] = [:]
    private var next = 0

    public init(limit: Int = 512) {
        self.limit = max(limit, 1)
    }

    /// `id`'s home slot among `count`, given one if it has none yet.
    public mutating func slot(for id: ID, count: Int) -> Int {
        let count = max(count, 1)
        if let home = homes[id] { return home % count }
        if homes.count >= limit {
            homes.removeAll(keepingCapacity: true)
            next = 0
        }
        let home = next
        homes[id] = home
        next += 1
        return home % count
    }
}
