import Foundation
@testable import OTMKit
import Testing

private func coreType(_ level: Int, _ name: String, cores: Int, perL2: Int? = nil) -> ChipLayout.CoreType {
    ChipLayout.CoreType(level: level, name: name, physicalCores: cores, logicalCores: cores, l1InstructionBytes: 128 << 10,
                        l1DataBytes: 64 << 10, l2Bytes: 8 << 20, coresPerL2: perL2)
}

private func layout(_ types: [ChipLayout.CoreType], _ clusters: [ChipLayout.Cluster]) -> ChipLayout {
    ChipLayout(chip: "Test chip", model: nil, architecture: "arm64", coreTypes: types, clusters: clusters, l3Bytes: nil,
               cacheLineBytes: 128, gpus: [], neuralEngine: nil, memoryBytes: 8 << 30, memoryType: nil)
}

/// CPUs `range` in device-tree cluster `cluster` of type `type`.
private func cpus(_ range: ClosedRange<Int>, cluster: Int?, type: String?) -> [ChipLayout.DeviceTreeCPU] {
    range.map { ChipLayout.DeviceTreeCPU(cpu: $0, cluster: cluster, type: type) }
}

struct ChipLayoutTests {
    /// An M5 Pro: 12 Performance cores in two clusters, 6 Super in one.
    private let proTypes = [coreType(0, "Super", cores: 6, perL2: 6), coreType(1, "Performance", cores: 12, perL2: 6)]
    private let proCPUs = cpus(0...5, cluster: 0, type: "M") + cpus(6...11, cluster: 1, type: "M") + cpus(12...17, cluster: 2, type: "P")

    @Test func groupsAProChipsClustersByKindOfCore() {
        let clusters = ChipLayout.clusters(from: proCPUs, coreTypes: proTypes, levelForType: ["P": 0, "M": 1])
        #expect(clusters.map(\.id) == [0, 1, 2])
        #expect(clusters.map(\.level) == [1, 1, 0])
        #expect(clusters.map(\.type) == ["M", "M", "P"])

        let chip = layout(proTypes, clusters)
        #expect(chip.clusters(of: 0).map(\.cpus) == [Array(12...17)])
        #expect(chip.clusters(of: 1).map(\.cpus) == [Array(0...5), Array(6...11)])
        #expect(chip.cpus(of: 1) == Array(0...11))
        #expect(chip.cpus(of: 0) == Array(12...17))
        #expect(chip.coreSummary == "18 cores: 6 Super, 12 Performance")
    }

    /// A virtual machine: one kind of core, one cluster, no cluster types.
    @Test func givesAVirtualMachinesOneClusterItsOnlyKindOfCore() {
        let types = [coreType(0, "Standard", cores: 6, perL2: 6)]
        let clusters = ChipLayout.clusters(from: cpus(0...5, cluster: 0, type: nil), coreTypes: types, levelForType: [:])
        #expect(clusters == [ChipLayout.Cluster(id: 0, type: nil, level: 0, cpus: Array(0...5))])
        let chip = layout(types, clusters)
        #expect(chip.cpus(of: 0) == Array(0...5))
        #expect(chip.coreSummary == "6 cores")
    }

    @Test func doesntGuessWhatTheDeviceTreeLeavesOut() {
        // A CPU without a cluster: no clusters at all, rather than a partial picture.
        let missing = cpus(0...4, cluster: 0, type: "E") + cpus(5...5, cluster: nil, type: "E")
        #expect(ChipLayout.clusters(from: missing, coreTypes: proTypes, levelForType: ["E": 1]).isEmpty)
        #expect(ChipLayout.clusters(from: [], coreTypes: proTypes, levelForType: [:]).isEmpty)

        // With two kinds of core, an unmapped type gets no level.
        let unmapped = ChipLayout.clusters(from: proCPUs, coreTypes: proTypes, levelForType: ["P": 0])
        #expect(unmapped.map(\.level) == [nil, nil, 0])
        #expect(layout(proTypes, unmapped).cpus(of: 1) == nil)

        // A type whose CPU count isn't its core type's isn't trusted.
        let short = cpus(0...5, cluster: 0, type: "M") + cpus(12...17, cluster: 2, type: "P")
        let clusters = ChipLayout.clusters(from: short, coreTypes: proTypes, levelForType: ["P": 0, "M": 1])
        #expect(clusters.map(\.level) == [nil, 0])

        // A cluster mixing types has neither a type nor a level.
        let mixed = cpus(0...2, cluster: 0, type: "P") + cpus(3...5, cluster: 0, type: "M")
        let mixedClusters = ChipLayout.clusters(from: mixed, coreTypes: proTypes, levelForType: ["P": 0, "M": 1])
        #expect(mixedClusters.map(\.type) == [nil])
        #expect(mixedClusters.map(\.level) == [nil])
    }

    @Test func countsSharedL2s() {
        #expect(coreType(1, "Performance", cores: 12, perL2: 6).l2Count == 2)
        #expect(coreType(0, "Super", cores: 6, perL2: 6).l2Count == 1)
        #expect(coreType(0, "Odd", cores: 5, perL2: 6).l2Count == nil)
        #expect(coreType(0, "Unknown", cores: 6).l2Count == nil)
    }

    @Test func writesCPURuns() {
        #expect(ChipLayout.cpuRanges(Array(0...5)) == "0–5")
        #expect(ChipLayout.cpuRanges([11, 8, 0, 1, 2, 10]) == "0–2, 8, 10–11")
        #expect(ChipLayout.cpuRanges([4, 4]) == "4")
        #expect(ChipLayout.cpuRanges([]) == "")
    }

    @Test func readsTheMemoryTypeOnlyWhenItsReal() {
        func parse(_ json: String) -> String? { ChipLayout.memoryType(fromSystemProfiler: Data(json.utf8)) }
        #expect(parse(#"{"SPMemoryDataType":[{"dimm_type":"LPDDR5","SPMemoryDataType":"48 GB"}]}"#) == "LPDDR5")
        #expect(parse(#"{"SPMemoryDataType":[{"dimm_type":"unknown","SPMemoryDataType":"8 GB"}]}"#) == nil)
        #expect(parse(#"{"SPMemoryDataType":[{"dimm_type":"DDR4"},{"dimm_type":"empty"},{"dimm_type":"DDR4"}]}"#) == "DDR4")
        #expect(parse(#"{"SPMemoryDataType":[{"dimm_type":"DDR4"},{"dimm_type":"DDR3"}]}"#) == nil)
        #expect(parse(#"{"SPMemoryDataType":[{"SPMemoryDataType":"8 GB"}]}"#) == nil)
        #expect(parse("not json") == nil)
    }

    @Test func roundTripsAsJSON() throws {
        let chip = layout(proTypes, ChipLayout.clusters(from: proCPUs, coreTypes: proTypes, levelForType: ["P": 0, "M": 1]))
        let decoded = try JSONDecoder().decode(ChipLayout.self, from: JSONEncoder().encode(chip))
        #expect(decoded == chip)
    }

    /// The real Mac's layout agrees with the topology the CPU page uses.
    @Test func readsThisMac() {
        let topology = CPUTopologyReader.read()
        let chip = ChipLayoutReader.read(topology: topology)
        #expect(!chip.coreTypes.isEmpty)
        #expect(chip.coreTypes.reduce(0) { $0 + $1.logicalCores } == topology.logicalCores)
        #expect(chip.memoryBytes == ProcessInfo.processInfo.physicalMemory)
        // Clusters, where the device tree gives them, cover every CPU once.
        if !chip.clusters.isEmpty {
            #expect(chip.clusters.flatMap(\.cpus).sorted() == Array(0..<topology.logicalCores))
        }
        for type in chip.coreTypes {
            if let cpus = chip.cpus(of: type.level) {
                // The device tree's grouping agrees with the kernel's tier for each CPU.
                #expect(cpus.allSatisfy { topology.tierForCPU.indices.contains($0) && topology.tierForCPU[$0] == type.level })
            }
        }
    }
}
