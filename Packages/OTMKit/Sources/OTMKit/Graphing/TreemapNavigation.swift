import CoreGraphics

/// Arrow keys follow the drawn geometry, including tiles too small for a label.
public enum TreemapNavigation {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// A selectable region in the treemap's coordinates, y down.
    public struct Tile: Sendable {
        public let id: Int
        public let rect: CGRect

        public init(id: Int, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    private struct Candidate {
        let id: Int
        let inLane: Bool
        let distance: CGFloat
        let centerDistance: CGFloat

        func precedes(_ other: Self) -> Bool {
            if inLane != other.inLane { return inLane }
            if distance != other.distance { return distance < other.distance }
            return centerDistance < other.centerDistance
        }
    }

    /// Prefer a neighbour sharing the current tile's row or column, then the
    /// closest edges and centres. Ties keep layout order; edges never wrap.
    /// With no current tile, the first valid region starts the selection.
    public static func next(from id: Int?, direction: Direction, tiles: [Tile]) -> Int? {
        let valid = tiles.filter { valid($0.rect) }
        guard let current = valid.first(where: { $0.id == id }) else { return valid.first?.id }
        let horizontal = direction == .left || direction == .right
        let forward = direction == .right || direction == .down
        let origin = current.rect
        var best: Candidate?
        for tile in valid where tile.id != current.id {
            let rect = tile.rect
            let along = horizontal ? rect.midX - origin.midX : rect.midY - origin.midY
            guard forward ? along > 0 : along < 0 else { continue }
            let crossGap = horizontal
                ? max(rect.minY - origin.maxY, origin.minY - rect.maxY, 0)
                : max(rect.minX - origin.maxX, origin.minX - rect.maxX, 0)
            let alongGap = horizontal
                ? max(rect.minX - origin.maxX, origin.minX - rect.maxX, 0)
                : max(rect.minY - origin.maxY, origin.minY - rect.maxY, 0)
            let cross = horizontal ? rect.midY - origin.midY : rect.midX - origin.midX
            let candidate = Candidate(id: tile.id, inLane: crossGap == 0,
                                      distance: alongGap * alongGap + crossGap * crossGap,
                                      centerDistance: along * along + cross * cross)
            if best.map({ candidate.precedes($0) }) ?? true { best = candidate }
        }
        return best?.id ?? current.id
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
