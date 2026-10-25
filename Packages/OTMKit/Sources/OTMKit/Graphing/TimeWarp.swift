/// Where a squeezed graph (`Settings.squeezesOlderTime`) puts each age: the
/// newest window keeps its usual scale over most of the width at the right,
/// and older time is squeezed to its left in zones, each older one harder
/// than the last, so one graph covers 15 windows.
///
/// Ages are in windows (1 is the newest window's oldest end, 5 min at the
/// usual speed); offsets are shares of the width from the right edge, 0 at
/// now and 1 at the oldest age the graph holds. Between stops the map is
/// linear, so each zone is an even scale of its own.
public struct TimeWarp: Sendable, Equatable {
    /// A zone's older end: its age and the offset reached there.
    public struct Stop: Sendable, Equatable {
        public var age: Double
        public var offset: Double

        public init(age: Double, offset: Double) {
            self.age = age
            self.offset = offset
        }
    }

    /// From now, `(0, 0)`, to the oldest age at offset 1, both rising.
    public let stops: [Stop]

    public init(stops: [Stop]) {
        precondition(stops.count >= 2 && stops.first == Stop(age: 0, offset: 0) && stops.last?.offset == 1,
                     "A warp runs from now at the right edge to offset 1")
        precondition(zip(stops, stops.dropFirst()).allSatisfy { $0.age < $1.age && $0.offset < $1.offset },
                     "A warp's stops rise in age and offset")
        self.stops = stops
    }

    /// The newest window over 60% of the width; then, for a 5-minute window,
    /// 5 to 15 min over 18%, 15 to 35 min over 12% and 35 min to 1 h 15 min
    /// over the last 10%: each zone squeezed harder than the one before it,
    /// the oldest still about a pixel per 10 s, so a burst there still shows.
    public static let standard = TimeWarp(stops: [
        Stop(age: 0, offset: 0), Stop(age: 1, offset: 0.6), Stop(age: 3, offset: 0.78),
        Stop(age: 7, offset: 0.9), Stop(age: 15, offset: 1),
    ])

    /// Windows the whole width covers.
    public var span: Double { stops[stops.count - 1].age }

    /// The share of the width the newest window keeps at its usual scale.
    public var linearShare: Double { stops[1].offset }

    /// The ages where one zone gives way to the next, newest first: the
    /// newest window's end, then each squeezed zone's but the last.
    public var zoneEdges: [Double] { stops.dropFirst().dropLast().map(\.age) }

    /// Width per window of age in each zone, newest first.
    public var densities: [Double] {
        zip(stops, stops.dropFirst()).map { ($1.offset - $0.offset) / ($1.age - $0.age) }
    }

    /// The offset of `age`, clamped to the graph.
    public func offset(age: Double) -> Double {
        guard age > 0 else { return 0 }
        var index = 1
        while index < stops.count {
            let stop = stops[index]
            if age <= stop.age {
                let previous = stops[index - 1]
                return previous.offset + (age - previous.age) / (stop.age - previous.age) * (stop.offset - previous.offset)
            }
            index += 1
        }
        return 1
    }

    /// The age at `offset`, clamped to the graph: `offset(age:)` undone.
    public func age(offset: Double) -> Double {
        guard offset > 0 else { return 0 }
        var index = 1
        while index < stops.count {
            let stop = stops[index]
            if offset <= stop.offset {
                let previous = stops[index - 1]
                return previous.age + (offset - previous.offset) / (stop.offset - previous.offset) * (stop.age - previous.age)
            }
            index += 1
        }
        return span
    }
}
