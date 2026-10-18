/// A graph series' older time, for a squeezed graph (`TimeWarp`): its
/// samples gathered into buckets of a few, each keeping their mean and
/// peak, so an hour and a quarter costs a few hundred figures rather than
/// thousands. `LongHistories` closes every series' bucket at once, so they
/// line up.
public struct LongHistory: Sendable {
    public struct Bucket: Sendable, Equatable {
        /// NaN where nothing was recorded (a gap, or the series not yet read).
        public var mean: Double
        public var peak: Double

        public init(mean: Double, peak: Double) {
            self.mean = mean
            self.peak = peak
        }

        public static let unrecorded = Bucket(mean: .nan, peak: .nan)

        public var isRecorded: Bool { mean.isFinite }
    }

    public let capacity: Int
    /// Closed buckets, oldest first. Changed only as one closes, so a graph
    /// can hold on to it between closes without copying it.
    public private(set) var buckets: [Bucket] = []
    /// The highest peak among `buckets`, or 0.
    public private(set) var peak = 0.0
    /// Buckets in `buckets` with something recorded.
    private var recorded = 0
    private var sum = 0.0
    private var weight = 0.0
    private var top = -Double.infinity

    public init(capacity: Int) {
        precondition(capacity > 0, "A long history keeps at least one bucket")
        self.capacity = capacity
    }

    /// Whether every bucket kept is unrecorded.
    public var isEmpty: Bool { recorded == 0 && weight == 0 }

    /// Counts `value` into the open bucket as `weight` samples (a hidden
    /// tick at twice the graphs' step is two). Values that aren't finite are
    /// left out, as a graph leaves them on its baseline.
    public mutating func add(_ value: Double, weight: Double = 1) {
        guard value.isFinite, weight > 0 else { return }
        sum += value * weight
        self.weight += weight
        if value > top { top = value }
    }

    /// Closes the open bucket: unrecorded if nothing was added to it.
    public mutating func close() {
        let bucket = weight > 0 ? Bucket(mean: sum / weight, peak: top) : .unrecorded
        sum = 0
        weight = 0
        top = -.infinity
        push([bucket])
    }

    /// Adds `count` unrecorded buckets: a stretch nothing was sampled in,
    /// such as sleep. Close the open bucket first.
    public mutating func skip(_ count: Int) {
        guard count > 0 else { return }
        push(Array(repeating: .unrecorded, count: min(count, capacity)))
    }

    private mutating func push(_ new: [Bucket]) {
        buckets.append(contentsOf: new)
        recorded += new.count { $0.isRecorded }
        let excess = buckets.count - capacity
        var droppedPeak = false
        if excess > 0 {
            for bucket in buckets[..<excess] where bucket.isRecorded {
                recorded -= 1
                if bucket.peak >= peak { droppedPeak = true }
            }
            buckets.removeFirst(excess)
        }
        if droppedPeak {
            peak = buckets.reduce(0) { $1.isRecorded ? max($0, $1.peak) : $0 }
        } else {
            for bucket in new where bucket.isRecorded && bucket.peak > peak { peak = bucket.peak }
        }
    }
}

/// Every squeezed series' older time (`LongHistory`), keyed by series. A
/// tick's figures go into each series' open bucket; once a bucket's worth
/// of samples is in, every series closes its bucket together, so their
/// buckets line up and a graph redraws its older time once per bucket,
/// never per tick. A series that has gone (a disk ejected) leaves once it
/// has nothing recorded left.
public struct LongHistories<Key: Hashable & Sendable>: Sendable {
    /// Samples per bucket.
    public let bucketSize: Int
    /// Buckets per series: `windows` of `span` samples.
    public let capacity: Int
    /// Counts closed buckets, so a graph knows when to redraw its older time.
    public private(set) var revision = 0
    private var series: [Key: LongHistory] = [:]
    /// Samples in the open bucket.
    private var filled = 0
    /// The tick under way's weight, in samples.
    private var weight = 1

    public init(span: Int, bucketSize: Int = 10, windows: Double = TimeWarp.standard.span) {
        precondition(span > 0 && bucketSize > 0, "A long history needs a window and buckets")
        self.bucketSize = bucketSize
        capacity = Int((Double(span) * windows / Double(bucketSize)).rounded(.up))
    }

    public var isEmpty: Bool { series.isEmpty }

    /// A series' closed buckets, oldest first; nil for one never recorded.
    public func buckets(_ key: Key) -> [LongHistory.Bucket]? {
        series[key]?.buckets
    }

    /// A series' highest closed peak, or 0.
    public func peak(_ key: Key) -> Double {
        series[key]?.peak ?? 0
    }

    /// Starts a tick worth `weight` samples: 1 at the graphs' step, more
    /// for a slower hidden tick, which then fills its share of the bucket.
    public mutating func startTick(weight: Int = 1) {
        self.weight = max(weight, 1)
    }

    public mutating func add(_ value: Double, for key: Key) {
        series[key, default: LongHistory(capacity: capacity)].add(value, weight: Double(weight))
    }

    /// Ends the tick, closing every series' bucket once it's full. True
    /// when they closed.
    @discardableResult
    public mutating func finishTick() -> Bool {
        filled += weight
        guard filled >= bucketSize else { return false }
        filled = 0
        closeAll(closing: true, skipping: 0)
        return true
    }

    /// A stretch of `samples` nothing was sampled in (the Mac slept):
    /// closes the open buckets, if anything is in them, and marks the
    /// stretch unrecorded.
    public mutating func gap(samples: Int) {
        let open = filled > 0
        filled = 0
        closeAll(closing: open, skipping: max(samples, 0) / bucketSize)
    }

    public mutating func removeAll() {
        series.removeAll()
        filled = 0
        revision += 1
    }

    private mutating func closeAll(closing: Bool, skipping: Int) {
        for key in Array(series.keys) {
            if closing { series[key]?.close() }
            series[key]?.skip(skipping)
            if series[key]?.isEmpty == true { series[key] = nil }
        }
        revision += 1
    }
}
