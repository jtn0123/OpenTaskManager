import Foundation

/// Version 1 discards one full pass, then measures the selected repeats in fixed order.
public enum BenchmarkSessionProtocol {
    public static let version = 1
    public static let repeats = 3
    public static let repeatRange = 1...10

    /// Pass zero is a full warm-up, followed by the selected number of measured passes.
    public static func passes(repeatCount: Int = repeats) -> ClosedRange<Int> {
        0...min(max(repeatCount, repeatRange.lowerBound), repeatRange.upperBound)
    }

    public static func kinds(_ selection: String) -> [BenchmarkKind]? {
        switch selection {
        case "cpu": [.cpu]
        case "gpu": [.gpu]
        case "all": [.cpu, .gpu]
        default: nil
        }
    }
}

/// Optional on each history result. Unknown versions retain their identity but never compare.
public struct BenchmarkSession: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var id: String
    public var protocolVersion: Int
    public var preflight: BenchmarkPreflight?
    /// Measured passes start at 1. The warm-up is never stored.
    public var repeatIndex: Int
    public var repeatCount: Int
    /// Filled only on a grouped envelope, so a cancelled session never appears complete.
    public var recordedRepeats: Int?

    public init(id: String, protocolVersion: Int = BenchmarkSessionProtocol.version, preflight: BenchmarkPreflight?,
                repeatIndex: Int, repeatCount: Int = BenchmarkSessionProtocol.repeats) {
        version = Self.currentVersion
        self.id = id
        self.protocolVersion = protocolVersion
        self.preflight = preflight
        self.repeatIndex = repeatIndex
        self.repeatCount = repeatCount
    }

    public init(from decoder: any Decoder) throws {
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(id: "", protocolVersion: 0, preflight: nil, repeatIndex: 0)
            version = 0
            return
        }
        self.init(id: (try? fields.decode(String.self, forKey: .id)) ?? "",
                  protocolVersion: (try? fields.decode(Int.self, forKey: .protocolVersion)) ?? 0,
                  preflight: try? fields.decodeIfPresent(BenchmarkPreflight.self, forKey: .preflight),
                  repeatIndex: (try? fields.decode(Int.self, forKey: .repeatIndex)) ?? 0,
                  repeatCount: (try? fields.decode(Int.self, forKey: .repeatCount)) ?? 0)
        version = (try? fields.decode(Int.self, forKey: .version)) ?? 0
        recordedRepeats = try? fields.decodeIfPresent(Int.self, forKey: .recordedRepeats)
    }

    public var supported: Bool {
        version == Self.currentVersion && protocolVersion == BenchmarkSessionProtocol.version && !id.isEmpty
            && BenchmarkSessionProtocol.repeatRange.contains(repeatCount) && (1...repeatCount).contains(repeatIndex)
    }
}

public extension BenchmarkRun {
    var sessionSummary: String {
        guard let session else { return "Not part of a session" }
        let repeats = session.recordedRepeats.map { "\($0) of \(session.repeatCount) measured repeats" }
            ?? "repeat \(session.repeatIndex) of \(session.repeatCount)"
        return "Session · protocol v\(session.protocolVersion) · " + repeats
    }

    /// Repeats become one read-only entry. Keep incompatible or incomplete groups visible with an explicit caveat.
    static func groupedSessions(_ runs: [Self]) -> [Self] {
        var groups: [String: [Self]] = [:]
        var singles: [Self] = []
        for run in runs {
            guard let session = run.session, !session.id.isEmpty else {
                singles.append(run)
                continue
            }
            if run.id.hasPrefix("session:") {
                singles.append(run)
                continue
            }
            let key = "\(run.kind.rawValue):\(session.id):\(session.protocolVersion)"
            groups[key, default: []].append(run)
        }
        for members in groups.values {
            let ordered = members.sorted { ($0.session?.repeatIndex ?? 0) < ($1.session?.repeatIndex ?? 0) }
            guard var entry = ordered.first, let session = entry.session else { continue }
            let compatible = ordered.allSatisfy {
                $0.id == entry.id || BenchmarkComparison.refusal(entry, $0) == nil
            }
            guard compatible else {
                singles += ordered
                continue
            }
            entry.id = "session:\(entry.kind.rawValue):\(session.id):\(session.protocolVersion)"
            entry.date = ordered.last?.date ?? entry.date
            entry.session?.recordedRepeats = ordered.count
            entry.conditions = ordered.reduce(into: [String]()) { conditions, run in
                for condition in run.conditions where !conditions.contains(condition) { conditions.append(condition) }
            }
            let indices = Set(ordered.compactMap { $0.session?.repeatIndex })
            let complete = session.supported && indices == Set(1...session.repeatCount) && indices.count == ordered.count
            if !complete { entry.conditions.append("Session incomplete or unsupported; recorded repeats only") }
            entry.measurements = entry.measurements.compactMap { reference in
                let figures = ordered.compactMap { $0.measurement(reference.id) }
                guard figures.count == ordered.count, figures.allSatisfy({ $0.value.isFinite }) else { return nil }
                var figure = BenchmarkMeasurement(id: reference.id, name: reference.name, variant: reference.variant,
                                                  repeats: figures.map(\.value), unit: reference.unit,
                                                  caveat: figures.compactMap(\.caveat).first)
                // Include each pass's internal spread so a session cannot hide timing noise.
                figure.low = figures.map { $0.low ?? $0.value }.min()
                figure.high = figures.map { $0.high ?? $0.value }.max()
                if figures.count == 1 { figure.repeats = nil; figure.low = nil; figure.high = nil }
                return figure
            }
            singles.append(entry)
        }
        return singles.sorted { $0.date > $1.date }
    }
}
