import Foundation

/// Turns one ordered list of unique ids into another with removals, moves and
/// inserts: the operations a table needs to keep its existing rows rather than
/// rebuilding them all.
public enum OrderedDiff {
    public enum Step: Equatable, Sendable {
        /// Move the element at `from` so it ends up at `to`.
        case move(from: Int, to: Int)
        /// Insert the new list's element at `at`.
        case insert(at: Int)
    }

    public struct Changes: Equatable, Sendable {
        /// Indexes in the old list, removed together before any step runs.
        public var removals: [Int]
        /// Applied in order after the removals.
        public var steps: [Step]

        public var count: Int { removals.count + steps.count }
        public var isEmpty: Bool { count == 0 }
    }

    /// `old` and `new` must not contain duplicates.
    ///
    /// The longest run of survivors already in the right relative order stays
    /// put; only the rest move, each at most twice. So one row sinking fifty
    /// places is one move, not fifty.
    public static func changes<ID: Hashable>(from old: [ID], to new: [ID]) -> Changes {
        let target = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1, $0) })
        let removals = old.indices.filter { target[old[$0]] == nil }
        var current = old.filter { target[$0] != nil }
        let anchored = Set(longestIncreasingSubsequence(current.map { target[$0]! }).map { current[$0] })
        let survivors = Set(current)

        var steps: [Step] = []
        // Walk the target order; everything before `index` is already in place.
        var index = 0
        while index < new.count {
            let id = new[index]
            if index < current.count, current[index] == id {
                index += 1
            } else if !survivors.contains(id) {
                steps.append(.insert(at: index))
                current.insert(id, at: index)
                index += 1
            } else if !anchored.contains(id), let from = current[index...].firstIndex(of: id) {
                steps.append(.move(from: from, to: index))
                current.insert(current.remove(at: from), at: index)
                index += 1
            } else {
                // An anchored row is due here but a row that belongs further
                // down is in the way: park that one at the end for now.
                steps.append(.move(from: index, to: current.count - 1))
                current.append(current.remove(at: index))
            }
        }
        return Changes(removals: removals, steps: steps)
    }

    /// Indexes into `values` of one longest strictly increasing subsequence.
    static func longestIncreasingSubsequence(_ values: [Int]) -> [Int] {
        // tails[k] is the index of the smallest value ending a run of length k + 1.
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.append(cursor)
            cursor = previous[cursor]
        }
        return result.reversed()
    }

    /// Replays `changes` on `old`, taking inserted elements from `new`.
    public static func apply<ID>(_ changes: Changes, to old: [ID], insertingFrom new: [ID]) -> [ID] {
        let removed = Set(changes.removals)
        var result = old.indices.filter { !removed.contains($0) }.map { old[$0] }
        for step in changes.steps {
            switch step {
            case let .move(from, to):
                result.insert(result.remove(at: from), at: to)
            case let .insert(at):
                result.insert(new[at], at: at)
            }
        }
        return result
    }
}
