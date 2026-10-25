/// A squeezed graph's older time laid out (`TimeWarp`): a series' buckets
/// (`LongHistory`) placed by age to the left of the newest window, and
/// merged into columns a device pixel wide wherever the warp packs them
/// closer than that, so drawing costs the same however much time a pixel
/// covers. Laid out once per closed bucket, never per tick.
public struct SqueezedTrace: Sendable, Equatable {
    /// A drawn point: its x from the graph's left edge, and the mean and peak
    /// of the buckets merged there; NaN where none of them was recorded.
    public struct Column: Sendable, Equatable {
        public var x: Double
        public var mean: Double
        public var peak: Double

        public var isRecorded: Bool { mean.isFinite }
    }

    /// A stretch with nothing recorded, from its left x to its right.
    public struct Gap: Sendable, Equatable {
        public var from: Double
        public var to: Double

        public init(from: Double, to: Double) {
            self.from = from
            self.to = to
        }
    }

    /// Left to right, the last at the newest window's left edge with the
    /// value of the bucket there, so the two parts of the line meet.
    public private(set) var columns: [Column] = []
    /// Left to right, including the stretch older than the oldest bucket.
    public private(set) var gaps: [Gap] = []

    /// Lays out `buckets` (oldest first, the newest just closed) of
    /// `bucketSize` samples each, in a graph `width` points wide whose
    /// newest window is `span` samples, at `scale` device pixels a point.
    public init(buckets: [LongHistory.Bucket], bucketSize: Int, span: Int, warp: TimeWarp = .standard,
                width: Double, scale: Double) {
        let size = Double(bucketSize)
        let windows = Double(span)
        func x(age: Double) -> Double { width * (1 - warp.offset(age: age / windows)) }
        let edge = width * (1 - warp.linearShare)
        let count = buckets.count
        // The newest bucket reaching past the newest window, counted back from the newest.
        let first = span / bucketSize
        guard count > first, width > 0 else {
            if edge > 0 { gaps = [Gap(from: 0, to: edge)] }
            return
        }

        // Newest first, from the window's edge leftwards.
        var placed: [Column] = []
        placed.reserveCapacity(min(count - first, Int(edge * scale) + 2))
        var unrecorded: [Gap] = []
        var pixel = Int.min
        var merged = (x: 0.0, xs: 0.0, sum: 0.0, recorded: 0.0, peak: -Double.infinity)
        func flush() {
            guard merged.xs > 0 else { return }
            let recorded = merged.recorded > 0
            placed.append(Column(x: merged.x / merged.xs, mean: recorded ? merged.sum / merged.recorded : .nan,
                                 peak: recorded ? merged.peak : .nan))
            merged = (0, 0, 0, 0, -.infinity)
        }
        var index = first
        while index < count {
            let bucket = buckets[count - 1 - index]
            let centre = x(age: (Double(index) + 0.5) * size)
            let column = Int((centre * scale).rounded(.down))
            if column != pixel {
                flush()
                pixel = column
            }
            merged.x += centre
            merged.xs += 1
            if bucket.isRecorded {
                merged.sum += bucket.mean
                merged.recorded += 1
                merged.peak = max(merged.peak, bucket.peak)
            } else {
                let right = min(x(age: Double(index) * size), edge)
                let left = x(age: Double(index + 1) * size)
                if let last = unrecorded.last, abs(last.from - right) < 1e-9 {
                    unrecorded[unrecorded.count - 1].from = left
                } else {
                    unrecorded.append(Gap(from: left, to: right))
                }
            }
            index += 1
        }
        flush()
        // Older than the oldest bucket: nothing recorded yet.
        let oldest = x(age: Double(count) * size)
        if oldest > 0 {
            if let last = unrecorded.last, abs(last.from - oldest) < 1e-9 {
                unrecorded[unrecorded.count - 1].from = 0
            } else {
                unrecorded.append(Gap(from: 0, to: oldest))
            }
        }
        let boundary = buckets[count - 1 - first]
        placed.insert(Column(x: edge, mean: boundary.isRecorded ? boundary.mean : .nan,
                             peak: boundary.isRecorded ? boundary.peak : .nan), at: 0)
        columns = placed.reversed()
        gaps = unrecorded.reversed()
    }
}
