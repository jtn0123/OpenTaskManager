import Foundation

public enum DockGraphMode: String, Sendable, CaseIterable, Identifiable {
    case off, cpu, memory
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .cpu: "CPU history"
        case .memory: "Memory history"
        }
    }
}

/// Quantized drawing inputs: a small bitmap only changes when its pixels do.
public struct DockGraphDrawing: Sendable, Equatable {
    public let mode: DockGraphMode
    public let heights: [Int?]
    public let percent: Int?
    public let paused: Bool
}

/// Sixty two-second slots. Missing observations stay gaps, including across
/// sleep or a pause; a slower update speed never stretches old time to fit.
public struct DockGraphFeed: Sendable {
    public static let points = 60
    public static let secondsPerPoint = 2.0
    public private(set) var mode = DockGraphMode.off
    private var paused = false
    private var history: [Double?] = []
    private var bucket: Double?
    private var latest: Double?
    private var lastDraw: TimeInterval?
    private var previous: DockGraphDrawing?

    public init() {}

    @discardableResult public mutating func setMode(_ mode: DockGraphMode) -> Bool {
        guard self.mode != mode else { return false }
        self.mode = mode
        history = []
        bucket = nil
        latest = nil
        previous = nil
        lastDraw = nil
        return true
    }

    public mutating func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        lastDraw = nil
    }

    public mutating func add(cpu: Double, memory: Double, at time: TimeInterval) {
        guard mode != .off, !paused, time.isFinite else { return }
        let nextBucket = floor(time / Self.secondsPerPoint)
        let raw = mode == .cpu ? cpu : memory
        let value: Double? = raw.isFinite ? min(max(raw, 0), 1) : nil
        if let bucket {
            let distance = nextBucket - bucket
            // A backwards clock starts a fresh span, never a negative range.
            if distance < 0 || distance >= Double(Self.points) {
                history = []
            } else if distance == 0 {
                if !history.isEmpty { history[history.count - 1] = value }
                latest = value
                return
            } else if distance > 1 {
                history += Array(repeating: nil, count: Int(distance) - 1)
            }
        }
        history.append(value)
        if history.count > Self.points { history.removeFirst(history.count - Self.points) }
        bucket = nextBucket
        latest = value
    }

    /// Advance cadence even for identical pixels. Rendering is suppressed
    /// while the screen is asleep; samples can still keep their real slots.
    public mutating func drawing(at time: TimeInterval, visible: Bool = true) -> DockGraphDrawing? {
        guard mode != .off, visible, time.isFinite,
              lastDraw.map({ time < $0 || time - $0 >= Self.secondsPerPoint }) ?? true else { return nil }
        lastDraw = time
        let next = DockGraphDrawing(mode: mode, heights: history.map { $0.map { Int(($0 * 36).rounded()) } },
                                    percent: latest.map { Int(($0 * 100).rounded()) }, paused: paused)
        guard next != previous else { return nil }
        previous = next
        return next
    }
}
