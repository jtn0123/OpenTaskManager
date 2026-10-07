import Foundation

/// What the chip is made of, as macOS reports it: each kind of CPU core with
/// its caches and clusters, the GPU's and Neural Engine's core counts, and
/// the memory. Read once (`ChipLayoutReader`); none of it changes while the
/// Mac runs. A part macOS doesn't report is nil or empty, never guessed.
public struct ChipLayout: Sendable, Codable, Equatable {
    /// One kind of CPU core, from the kernel's `hw.perflevelN` keys.
    public struct CoreType: Sendable, Codable, Equatable, Identifiable {
        public var id: Int { level }
        /// The N of `hw.perflevelN`: 0 is the fastest kind, as in `CPUTopology.Tier`.
        public let level: Int
        /// "Super", "Performance", "Efficiency"; "Standard" in a virtual machine.
        public let name: String
        public let physicalCores: Int
        public let logicalCores: Int
        /// Each core's own L1 caches.
        public let l1InstructionBytes: Int?
        public let l1DataBytes: Int?
        /// One L2's size, shared by `coresPerL2` cores.
        public let l2Bytes: Int?
        /// How many cores share each L2 (`cpusperl2`).
        public let coresPerL2: Int?

        public init(level: Int, name: String, physicalCores: Int, logicalCores: Int, l1InstructionBytes: Int?, l1DataBytes: Int?,
                    l2Bytes: Int?, coresPerL2: Int?) {
            self.level = level
            self.name = name
            self.physicalCores = physicalCores
            self.logicalCores = logicalCores
            self.l1InstructionBytes = l1InstructionBytes
            self.l1DataBytes = l1DataBytes
            self.l2Bytes = l2Bytes
            self.coresPerL2 = coresPerL2
        }

        /// How many separate L2s the cores share out, when the counts divide evenly.
        public var l2Count: Int? {
            guard let coresPerL2, coresPerL2 > 0, physicalCores % coresPerL2 == 0 else { return nil }
            return physicalCores / coresPerL2
        }
    }

    /// A group of CPUs the device tree puts in one cluster.
    public struct Cluster: Sendable, Codable, Equatable, Identifiable {
        /// The device tree's `logical-cluster-id`.
        public let id: Int
        /// Its `cluster-type` ("E", "P", "M"), when the device tree gives one.
        public let type: String?
        /// The `CoreType.level` of its CPUs; nil when the data doesn't settle it.
        public let level: Int?
        /// Logical CPU numbers, ascending: the numbers the CPU graphs use.
        public let cpus: [Int]

        public init(id: Int, type: String?, level: Int?, cpus: [Int]) {
            self.id = id
            self.type = type
            self.level = level
            self.cpus = cpus
        }
    }

    /// A GPU or the Neural Engine.
    public struct Engine: Sendable, Codable, Equatable {
        public let name: String
        /// nil when the I/O Registry doesn't give a count.
        public let cores: Int?

        public init(name: String, cores: Int?) {
            self.name = name
            self.cores = cores
        }
    }

    /// "Apple M5 Pro".
    public let chip: String
    /// "Mac17,8".
    public let model: String?
    public let architecture: String
    /// Fastest first.
    public let coreTypes: [CoreType]
    /// By id. Empty when the device tree doesn't group CPUs into clusters.
    public let clusters: [Cluster]
    public let l3Bytes: Int?
    public let cacheLineBytes: Int?
    public let gpus: [Engine]
    /// nil when the I/O Registry shows no Neural Engine.
    public let neuralEngine: Engine?
    public let memoryBytes: UInt64
    /// "LPDDR5", from system_profiler; nil when it says "unknown" or can't run.
    public var memoryType: String?

    public init(chip: String, model: String?, architecture: String, coreTypes: [CoreType], clusters: [Cluster], l3Bytes: Int?,
                cacheLineBytes: Int?, gpus: [Engine], neuralEngine: Engine?, memoryBytes: UInt64, memoryType: String?) {
        self.chip = chip
        self.model = model
        self.architecture = architecture
        self.coreTypes = coreTypes
        self.clusters = clusters
        self.l3Bytes = l3Bytes
        self.cacheLineBytes = cacheLineBytes
        self.gpus = gpus
        self.neuralEngine = neuralEngine
        self.memoryBytes = memoryBytes
        self.memoryType = memoryType
    }

    /// The clusters of one kind of core, by id.
    public func clusters(of level: Int) -> [Cluster] {
        clusters.filter { $0.level == level }
    }

    /// The CPUs of one kind of core, when the device tree's clusters account
    /// for all of them; nil otherwise, rather than a guess from the numbering.
    public func cpus(of level: Int) -> [Int]? {
        guard let type = coreTypes.first(where: { $0.level == level }) else { return nil }
        let cpus = clusters(of: level).flatMap(\.cpus).sorted()
        return cpus.count == type.logicalCores ? cpus : nil
    }

    /// "18 cores: 6 Super, 12 Performance" or "6 cores".
    public var coreSummary: String {
        let total = coreTypes.reduce(0) { $0 + $1.physicalCores }
        let parts = coreTypes.map { "\($0.physicalCores) \($0.name)" }
        return coreTypes.count > 1 ? "\(total) cores: " + parts.joined(separator: ", ") : "\(total) cores"
    }

    // MARK: - Building from the device tree

    /// One CPU as the device tree lists it.
    public struct DeviceTreeCPU: Sendable, Equatable {
        public let cpu: Int
        public let cluster: Int?
        public let type: String?

        public init(cpu: Int, cluster: Int?, type: String?) {
            self.cpu = cpu
            self.cluster = cluster
            self.type = type
        }
    }

    /// Groups the device tree's CPUs into clusters and gives each the level
    /// of its CPUs. `levelForType` maps cluster types to core types (see
    /// `CPUTopologyReader.levels`); a type whose CPU count doesn't match its
    /// core type's is left without a level. With one kind of core, every
    /// cluster is that kind. Empty unless every CPU names its cluster.
    public static func clusters(from cpus: [DeviceTreeCPU], coreTypes: [CoreType], levelForType: [String: Int]) -> [Cluster] {
        guard !cpus.isEmpty, cpus.allSatisfy({ $0.cluster != nil }) else { return [] }
        var counts: [String: Int] = [:]
        for cpu in cpus { if let type = cpu.type { counts[type, default: 0] += 1 } }
        func level(_ type: String?) -> Int? {
            if coreTypes.count == 1 { return coreTypes[0].level }
            guard let type, let level = levelForType[type],
                  coreTypes.first(where: { $0.level == level })?.logicalCores == counts[type] else { return nil }
            return level
        }
        let grouped = Dictionary(grouping: cpus) { $0.cluster ?? 0 }
        return grouped.keys.sorted().map { id in
            let members = grouped[id] ?? []
            let types = Set(members.map(\.type))
            let type = types.count == 1 ? members.first?.type : nil
            return Cluster(id: id, type: type, level: types.count == 1 ? level(type) : nil, cpus: members.map(\.cpu).sorted())
        }
    }

    // MARK: - Words

    /// "0–5", "0–5, 8, 10–11": runs of CPU numbers.
    public static func cpuRanges(_ cpus: [Int]) -> String {
        var runs: [ClosedRange<Int>] = []
        for cpu in Set(cpus).sorted() {
            if let last = runs.last, cpu == last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...cpu
            } else {
                runs.append(cpu...cpu)
            }
        }
        return runs.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
    }

    /// The memory type system_profiler gives, or nil for a missing or
    /// placeholder value ("unknown" in a virtual machine).
    public static func memoryType(fromSystemProfiler data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPMemoryDataType"] as? [[String: Any]] else { return nil }
        let types = items.compactMap { ($0["dimm_type"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown" && $0.lowercased() != "empty" }
        guard let first = types.first, types.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
