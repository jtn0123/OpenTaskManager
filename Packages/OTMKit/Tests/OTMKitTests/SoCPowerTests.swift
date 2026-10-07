import Foundation
@testable import OTMKit
import Testing

/// Fixtures are channel names, state names and device-tree tables read from
/// an M5 Pro (6 Super + 12 Performance cores, 20-core GPU) on macOS 27.
struct SoCPowerTests {
    // MARK: Fixtures

    static func table(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (frequency, voltage) in pairs {
            withUnsafeBytes(of: frequency.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: voltage.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// pmgr `voltage-states5-sram`: the Super cluster's clocks in kHz.
    static let superClusterKHz: [UInt32] = [
        1_308_000, 1_620_000, 1_980_000, 2_292_000, 2_580_000, 2_880_000, 3_180_000, 3_432_000, 3_648_000, 3_828_000,
        3_984_000, 4_104_000, 4_188_000, 4_236_000, 4_284_000, 4_308_000, 4_332_000, 4_428_000, 4_512_000, 4_608_000,
    ]
    static var superClusterSRAM: Data { table(superClusterKHz.map { ($0, 1000) }) }
    /// pmgr `voltage-states5`: the same domain's plain table, which holds no clocks.
    static var superClusterPlain: Data {
        table([50103, 40454, 33098, 28593, 25401, 22755, 20608, 19095, 17964, 17120,
               16449, 15968, 15648, 15471, 15297, 15212, 15128, 14800, 14524, 14222].map { ($0, 900) })
    }

    /// The GPU node's `perf-states` (first table): Hz, with entry 0 powered off.
    static let gpuHz: [UInt32] = [
        0, 338_000_000, 486_000_000, 636_000_000, 796_000_000, 888_000_000, 988_000_000,
        1_084_000_000, 1_182_000_000, 1_278_000_000, 1_374_000_000, 1_470_000_000, 1_578_000_000, 1_620_000_000,
    ]
    static var gpuPerfStates: Data { table(gpuHz.map { ($0, 700) }) }

    /// pmgr `perf-domains`, verbatim.
    static let perfDomainsHex = """
    00040001000000002c010000534f4300000000000000000000000000\
    02040003000000002c01000044435300000000000000000000000000\
    05010105000000000000000050435055000000000000000000000000\
    080000080000000000000000414e4500000000000000000000000000\
    0b04000b000000002c01000044495350000000000000000000000000\
    1601011600000000000000004d435055300000000000000000000000\
    1701011700000000000000004d435055310000000000000000000000\
    1e04001e000000000000000044495350320000000000000000000000\
    1c00000f0000000000000000534f435f414643000000000000000000\
    1d0000100000000000000000534f435f414649000000000000000000\
    000000200000000000000000504d502d534f43000000000000000000\
    0000002e0000000000000000504552462d4150490000000000000000
    """

    static func data(hex: String) -> Data {
        var data = Data()
        var digits = hex.makeIterator()
        while let high = digits.next(), let low = digits.next() {
            data.append(UInt8(String([high, low]), radix: 16) ?? 0)
        }
        return data
    }

    static let tiers: [CPUTopology.Tier] = [
        .init(level: 0, name: "Super", logicalCPUs: 6, physicalCPUs: 6, l2CacheBytes: nil),
        .init(level: 1, name: "Performance", logicalCPUs: 12, physicalCPUs: 12, l2CacheBytes: nil),
    ]
    static let levels = ["P": 0, "M": 1]

    /// A cluster's complex states: DOWN, IDLE and `steps` voltage steps named
    /// like the M5 Pro's ("V0P19" ... "V19P0"), with residency only where given.
    static func clusterStates(steps: Int, idle: Int64, busy: [Int: Int64]) -> [IOReportChannel.State] {
        [.init(name: "DOWN", residency: 0), .init(name: "IDLE", residency: idle)]
            + (0..<steps).map { .init(name: "V\($0)P\(steps - 1 - $0)", residency: busy[$0] ?? 0) }
    }

    static func energy(_ name: String, _ value: Int64, unit: String = "mJ", driver: UInt64 = 1) -> IOReportChannel {
        IOReportChannel(group: "Energy Model", subgroup: "", name: name, unit: unit, driverID: driver, value: .integer(value))
    }

    static func cluster(_ name: String, _ states: [IOReportChannel.State]) -> IOReportChannel {
        IOReportChannel(group: "CPU Stats", subgroup: "CPU Complex Performance States", name: name, unit: "24Mticks",
                        driverID: 1, value: .states(states))
    }

    static let gpuDriver: UInt64 = 4_294_969_040

    /// GPUPH as read on the M5 Pro with a model running on the GPU.
    static var gpuStates: IOReportChannel {
        var states: [IOReportChannel.State] = [.init(name: "OFF", residency: 888_582)]
        let busy: [Int: Int64] = [1: 150_471, 11: 5564, 12: 14_111_996, 13: 9_086_763]
        states += (1...15).map { .init(name: "P\($0)", residency: busy[$0] ?? 0) }
        return IOReportChannel(group: "GPU Stats", subgroup: "GPU Performance States", name: "GPUPH", unit: "24Mticks",
                               driverID: gpuDriver, value: .states(states))
    }

    static func analyzer() -> SoCPowerAnalyzer {
        SoCPowerAnalyzer(
            tiers: tiers, levelForClusterType: levels,
            cpuTableCandidates: ["PCPU": [superClusterPlain, superClusterSRAM]],
            gpuTables: [gpuDriver: gpuHz.map { Double($0) / 1e6 }]
        )
    }

    /// One second of a live energy model: 2 W of CPU split over three clusters.
    static var liveInterval: [IOReportChannel] {
        [
            energy("PCPU", 1500), energy("MCPU0", 300), energy("MCPU1", 200), energy("CPU Energy", 2000),
            energy("GPU0", 2900), energy("ANE0", 100), energy("DRAM0", 400),
            energy("GPU Energy", 3_000_000_000, unit: "nJ", driver: gpuDriver),
            cluster("PCPU", clusterStates(steps: 20, idle: 500, busy: [0: 250, 19: 250])),
            cluster("MCPU0", clusterStates(steps: 15, idle: 1000, busy: [:])),
            cluster("MCPU1", clusterStates(steps: 15, idle: 0, busy: [14: 10])),
            gpuStates,
        ]
    }

    /// The M5 Pro's batched energy model: the power manager's counters stand
    /// still while the GPU driver's keep moving.
    static var batchedInterval: [IOReportChannel] {
        [
            energy("PCPU", 0), energy("MCPU0", 0), energy("MCPU1", 0), energy("CPU Energy", 0),
            energy("GPU0", 0), energy("ANE0", 0), energy("DRAM0", 0),
            energy("GPU Energy", 7_000_000, unit: "nJ", driver: gpuDriver),
            cluster("PCPU", clusterStates(steps: 20, idle: 900, busy: [19: 100])),
            gpuStates,
        ]
    }

    // MARK: Names and units

    @Test func parsesClusterChannelNames() {
        #expect(CPUClusterChannel("PCPU") == CPUClusterChannel("PCPU0"))
        #expect(CPUClusterChannel("PCPU")?.type == "P")
        #expect(CPUClusterChannel("PCPU")?.index == 0)
        #expect(CPUClusterChannel("MCPU1")?.type == "M")
        #expect(CPUClusterChannel("MCPU1")?.index == 1)
        #expect(CPUClusterChannel("ECPU")?.type == "E")
        for name in ["CPU Energy", "MCPU0_0", "PCPU0_SRAM", "MCPU0DTL00", "PACC_0", "PCPM", "MCPM0", "CPU0", "pCPU", ""] {
            #expect(CPUClusterChannel(name) == nil, "\(name)")
        }
    }

    @Test func classifiesEnergyModelChannels() {
        #expect(EnergyChannelRole(channel: "CPU Energy") == .cpuTotal)
        #expect(EnergyChannelRole(channel: "PCPU") == .cluster("PCPU"))
        #expect(EnergyChannelRole(channel: "MCPU1") == .cluster("MCPU1"))
        #expect(EnergyChannelRole(channel: "GPU Energy") == .gpuDriver)
        #expect(EnergyChannelRole(channel: "GPU0") == .gpuPowerManager)
        #expect(EnergyChannelRole(channel: "ANE0") == .ane)
        #expect(EnergyChannelRole(channel: "DRAM0") == .dram)
        // The rest of the M5 Pro's 364 channels are parts of these or other blocks.
        let ignored = ["AFR0", "ISP0", "AVE0", "MSR0", "AMCC0", "DCS0", "DISP0", "DISPEXT0", "FAB0", "PCIe Port 0",
                       "apciec0 Energy", "MCPM0", "PCPM", "MCPU0_0", "PACC_0", "MCPU0_0_SRAM", "PCPU0_SRAM",
                       "MCPU0DTL00", "ANE_SRAM", "GPU_SRAM"]
        for name in ignored {
            #expect(EnergyChannelRole(channel: name) == nil, "\(name)")
        }
    }

    @Test func convertsEnergyUnits() {
        #expect(EnergyUnit.joulesPerUnit("mJ") == 1e-3)
        #expect(EnergyUnit.joulesPerUnit(" uJ") == 1e-6)
        #expect(EnergyUnit.joulesPerUnit("\u{00B5}J") == 1e-6)
        #expect(EnergyUnit.joulesPerUnit("nJ") == 1e-9)
        #expect(EnergyUnit.joulesPerUnit("J") == 1)
        #expect(EnergyUnit.joulesPerUnit("24Mticks") == nil)
    }

    @Test func subscribesOnlyToChannelsItUses() {
        #expect(SoCPowerAnalyzer.wants(group: "Energy Model", channel: "CPU Energy"))
        #expect(!SoCPowerAnalyzer.wants(group: "Energy Model", channel: "MCPU0DTL00"))
        #expect(SoCPowerAnalyzer.wants(group: "CPU Stats", channel: "MCPU1"))
        #expect(SoCPowerAnalyzer.wants(group: "GPU Stats", channel: "GPUPH"))
        #expect(!SoCPowerAnalyzer.wants(group: "SoC Stats", channel: "PCPU"))
    }

    // MARK: Clusters

    @Test func namesClustersAfterTheirTiers() {
        let slots = ClusterSlot.layout(channels: ["MCPU1", "PCPU", "MCPU0", "PCPU"], tiers: Self.tiers, levelForClusterType: Self.levels)
        #expect(slots == [
            ClusterSlot(channel: "PCPU", tierLevel: 0, name: "Super 0"),
            ClusterSlot(channel: "MCPU0", tierLevel: 1, name: "Performance 0"),
            ClusterSlot(channel: "MCPU1", tierLevel: 1, name: "Performance 1"),
        ])

        // An M1 Pro: two P clusters and one E cluster.
        let m1Tiers: [CPUTopology.Tier] = [
            .init(level: 0, name: "Performance", logicalCPUs: 8, physicalCPUs: 8, l2CacheBytes: nil),
            .init(level: 1, name: "Efficiency", logicalCPUs: 2, physicalCPUs: 2, l2CacheBytes: nil),
        ]
        let m1 = ClusterSlot.layout(channels: ["ECPU", "PCPU0", "PCPU1"], tiers: m1Tiers, levelForClusterType: ["P": 0, "E": 1])
        #expect(m1.map(\.name) == ["Performance 0", "Performance 1", "Efficiency 0"])

        // A cluster type the topology doesn't know keeps its channel name and sorts last.
        let unknown = ClusterSlot.layout(channels: ["XCPU", "PCPU"], tiers: Self.tiers, levelForClusterType: Self.levels)
        #expect(unknown.last == ClusterSlot(channel: "XCPU", tierLevel: nil, name: "XCPU"))
    }

    @Test func ranksClusterTypesByKernelOrder() {
        // M5 Pro: CPUs 0-11 are type M, 12-17 type P; the kernel lists the slowest tier first.
        var m5: [Int: String] = [:]
        for cpu in 0..<18 { m5[cpu] = cpu < 12 ? "M" : "P" }
        #expect(CPUTopologyReader.levels(forClusterTypes: m5, tierCount: 2) == ["P": 0, "M": 1])
        let m1: [Int: String] = [0: "E", 1: "E", 2: "P", 3: "P"]
        #expect(CPUTopologyReader.levels(forClusterTypes: m1, tierCount: 2) == ["P": 0, "E": 1])
        #expect(CPUTopologyReader.levels(forClusterTypes: m1, tierCount: 3) == nil)
        #expect(CPUTopologyReader.levels(forClusterTypes: [:], tierCount: 1) == nil)
    }

    // MARK: Residency and clocks

    @Test func weighsClocksByResidency() {
        let states: [IOReportChannel.State] = [
            .init(name: "DOWN", residency: 0), .init(name: "IDLE", residency: 100),
            .init(name: "V0P2", residency: 50), .init(name: "V1P1", residency: 0), .init(name: "V2P0", residency: 50),
        ]
        let table = [1000.0, 2000, 3000]
        let summary = Residency.summarize(states) { Residency.cpuStateIndex($0).map { table[$0] } }
        #expect(summary.activeFraction == 0.5)
        #expect(summary.frequencyMHz == 2000)

        let idle = Residency.summarize([.init(name: "IDLE", residency: 10)]) { _ in 1000 }
        #expect(idle == Residency.Summary(activeFraction: 0, frequencyMHz: nil))
        #expect(Residency.summarize([]) { _ in 1000 } == Residency.Summary())
    }

    @Test func withholdsTheClockWhenStatesAreUnmapped() {
        let table = Self.gpuHz.map { Double($0) / 1e6 }
        func clock(_ name: String) -> Double? {
            Residency.gpuStateIndex(name).flatMap { table.indices.contains($0) ? table[$0] : nil }
        }
        guard case .states(var states) = Self.gpuStates.value else { Issue.record("fixture"); return }
        let summary = Residency.summarize(states, frequencyMHz: clock)
        #expect(abs((summary.activeFraction ?? 0) - 0.963_347) < 1e-6)
        #expect(abs((summary.frequencyMHz ?? 0) - 1586.326) < 0.001)

        // P14 has no entry in the 14-entry table; 2% of active time there is too much to ignore.
        states[14] = .init(name: "P14", residency: 480_000)
        #expect(Residency.summarize(states, frequencyMHz: clock).frequencyMHz == nil)
        states[14] = .init(name: "P14", residency: 100_000)
        #expect(Residency.summarize(states, frequencyMHz: clock).frequencyMHz != nil)
    }

    @Test func parsesStateNames() {
        #expect(Residency.cpuStateIndex("V19P0") == 19)
        #expect(Residency.cpuStateIndex("V0P19") == 0)
        #expect(Residency.cpuStateIndex("IDLE") == nil)
        #expect(Residency.cpuStateIndex("VP3") == nil)
        #expect(Residency.gpuStateIndex("P13") == 13)
        #expect(Residency.gpuStateIndex("OFF") == nil)
        #expect(Residency.gpuStateIndex("P") == nil)
        #expect(Residency.gpuStateIndex("P1a") == nil)
    }

    // MARK: Device-tree tables

    @Test func decodesClockTables() throws {
        let superCluster = try #require(FrequencyTable.megahertz(from: Self.superClusterSRAM))
        #expect(superCluster.count == 20)
        #expect(superCluster.first == 1308)
        #expect(superCluster.last == 4608)
        #expect(FrequencyTable.megahertz(from: Self.superClusterPlain) == nil, "not clocks")

        let gpu = try #require(FrequencyTable.megahertz(from: Self.gpuPerfStates))
        #expect(gpu.count == 14)
        #expect(gpu[0] == 0)
        #expect(gpu[1] == 338)
        #expect(gpu[13] == 1620)

        // Two tables back to back only decode when limited to the first.
        let twoTables = Self.gpuPerfStates + Self.gpuPerfStates
        #expect(FrequencyTable.megahertz(from: twoTables) == nil)
        #expect(FrequencyTable.megahertz(from: twoTables, limit: 14) == gpu)

        #expect(FrequencyTable.megahertz(from: Self.table([(1, 645), (1, 745)])) == nil, "placeholder entries")
        #expect(FrequencyTable.megahertz(from: Self.table([(2_000_000_000, 0), (1_000_000_000, 0)])) == nil, "descending")
        #expect(FrequencyTable.megahertz(from: Data()) == nil)
    }

    @Test func mapsPerfDomainsToTables() {
        let tables = FrequencyTable.perfDomainTables(Self.data(hex: Self.perfDomainsHex))
        #expect(tables["PCPU"] == 5)
        #expect(tables["MCPU0"] == 22)
        #expect(tables["MCPU1"] == 23)
        #expect(tables["ANE"] == 8)
        #expect(tables["SOC_AFC"] == 28)
        #expect(tables.count == 12)
        #expect(FrequencyTable.perfDomainTables(Data([1, 2, 3])).isEmpty)
    }

    @Test func picksTheClusterTableWithOneEntryPerStep() {
        let candidates = [Self.superClusterPlain, Self.superClusterSRAM]
        #expect(FrequencyTable.clusterTable(candidates: candidates, stepCount: 20)?.last == 4608)
        #expect(FrequencyTable.clusterTable(candidates: candidates, stepCount: 15) == nil)
        // A table with a powered-off entry can't describe a cluster's steps.
        #expect(FrequencyTable.clusterTable(candidates: [Self.gpuPerfStates], stepCount: 14) == nil)
    }

    // MARK: Energy model health

    @Test func detectsABatchedEnergyModel() {
        var monitor = EnergyModelMonitor()
        struct Reading {
            let joules: Double
            let interval: Double
            let usable: Bool
            let batchedAfter: Bool
            /// Set aside as not live, which one interval can already tell.
            var stalled: Bool { !usable && interval >= EnergyModelMonitor.minimumInterval }
        }
        let readings = [
            Reading(joules: 2, interval: 1, usable: true, batchedAfter: false),
            Reading(joules: 0, interval: 0.1, usable: false, batchedAfter: false), // too short to judge
            Reading(joules: 0, interval: 1, usable: false, batchedAfter: false),
            Reading(joules: 2, interval: 1, usable: true, batchedAfter: false), // a live reading resets the count
            Reading(joules: 0, interval: 1, usable: false, batchedAfter: false),
            Reading(joules: 0, interval: 1, usable: false, batchedAfter: true), // the second zero in a row
            Reading(joules: 2, interval: 1, usable: false, batchedAfter: true), // batched for good
        ]
        for (step, reading) in readings.enumerated() {
            let usable = monitor.accept(cpuJoules: reading.joules, interval: reading.interval, limitWatts: 100)
            #expect(usable == reading.usable, "step \(step)")
            #expect(monitor.isBatched == reading.batchedAfter, "step \(step)")
            #expect(monitor.isStalled == reading.stalled, "step \(step)")
        }
    }

    @Test func rejectsABurstWithoutGivingUp() {
        var monitor = EnergyModelMonitor()
        let burst = monitor.accept(cpuJoules: 135, interval: 1, limitWatts: 60)
        #expect(monitor.isStalled, "a burst isn't a live reading either")
        let missing = monitor.accept(cpuJoules: nil, interval: 1, limitWatts: 60)
        #expect(!monitor.isStalled, "no CPU channel at all says nothing about the counters")
        let live = monitor.accept(cpuJoules: 5, interval: 1, limitWatts: 60)
        #expect(!burst)
        #expect(!missing)
        #expect(live)
        #expect(!monitor.isStalled)
        #expect(!monitor.isBatched)
        #expect(SoCPowerAnalyzer.limitWatts(systemWatts: 10) == 60)
        #expect(SoCPowerAnalyzer.limitWatts(systemWatts: nil) == PowerSourceSelection.maximumPlausibleWatts)
    }

    // MARK: Analysis

    @Test func readsALiveEnergyModel() throws {
        var analyzer = Self.analyzer()
        var askedSMC = false
        let result = analyzer.analyze(Self.liveInterval, interval: 1, systemWatts: 20) {
            askedSMC = true
            return 9
        }
        #expect(!askedSMC)
        let components = try #require(result.components)
        #expect(abs(components.cpu - 2) < 1e-9)
        #expect(abs(components.gpu - 3) < 1e-9, "the GPU driver's counter wins over the power manager's")
        #expect(abs(components.ane - 0.1) < 1e-9)
        #expect(abs((components.dram ?? 0) - 0.4) < 1e-9)
        #expect(abs(components.total - 5.5) < 1e-9)
        #expect(components.sources == [.cpu: .energyModel, .gpu: .energyModel, .ane: .energyModel, .dram: .energyModel])
        #expect(!components.energyCountersStalled)

        #expect(components.clusters.map(\.name) == ["Super 0", "Performance 0", "Performance 1"])
        #expect(components.clusters.map(\.tierLevel) == [0, 1, 1])
        let superCluster = components.clusters[0]
        #expect(abs((superCluster.watts ?? 0) - 1.5) < 1e-9)
        #expect(superCluster.activeFraction == 0.5)
        #expect(superCluster.frequencyMHz == 2958, "midway between 1308 and 4608 MHz")
        #expect(components.clusters[1].activeFraction == 0)
        #expect(components.clusters[1].frequencyMHz == nil, "idle")
        #expect(components.clusters[2].activeFraction == 1)
        #expect(components.clusters[2].frequencyMHz == nil, "no clock table for MCPU1 in the fixture")

        let gpu = try #require(result.gpus[Self.gpuDriver])
        #expect(abs((gpu.frequencyMHz ?? 0) - 1586.326) < 0.001)
    }

    @Test func addsUpClustersWithoutACPUTotal() throws {
        var analyzer = Self.analyzer()
        let channels = Self.liveInterval.filter { $0.name != "CPU Energy" }
        let result = analyzer.analyze(channels, interval: 0.5, systemWatts: nil) { nil }
        let components = try #require(result.components)
        #expect(abs(components.cpu - 4) < 1e-9, "2 J over half a second")
        #expect(components.sources[.cpu] == .energyModel)
    }

    @Test func fallsBackToTheSMCWhenTheEnergyModelIsBatched() throws {
        var analyzer = Self.analyzer()
        for _ in 0..<2 {
            let result = analyzer.analyze(Self.batchedInterval, interval: 1, systemWatts: 20) { 6.5 }
            let components = try #require(result.components)
            #expect(components.cpu == 6.5)
            #expect(components.sources == [.cpu: .smc, .gpu: .energyModel])
            #expect(abs(components.gpu - 0.007) < 1e-9)
            #expect(components.ane == 0)
            #expect(components.dram == nil)
            #expect(components.watts(.ane) == nil)
            #expect(components.clusters.allSatisfy { $0.watts == nil })
            #expect(components.clusters.first?.frequencyMHz == 4608)
            #expect(components.clusters.first?.activeFraction == 0.1)
            #expect(components.energyCountersStalled, "one interval reading zero already tells")
        }
        #expect(analyzer.energyModel.isBatched)

        // When the batch lands it's a burst worth kilowatts; it stays ignored.
        var burst = Self.liveInterval
        burst[3] = Self.energy("CPU Energy", 17_504_400)
        let result = analyzer.analyze(burst, interval: 1, systemWatts: 20) { 7 }
        let components = try #require(result.components)
        #expect(components.cpu == 7)
        #expect(components.sources[.cpu] == .smc)
        #expect(components.sources[.ane] == nil)
        #expect(components.energyCountersStalled, "says why the Neural Engine and DRAM go unmeasured")
    }

    @Test func leavesTheCPUUnmeasuredWithoutAnySource() throws {
        var analyzer = Self.analyzer()
        let result = analyzer.analyze(Self.batchedInterval, interval: 1, systemWatts: 20) { nil }
        let components = try #require(result.components)
        #expect(components.cpu == 0)
        #expect(!components.isMeasured(.cpu))
        #expect(components.watts(.cpu) == nil)
        #expect(components.watts(.gpu) != nil)

        // An implausible SMC reading is no better.
        let implausible = analyzer.analyze(Self.batchedInterval, interval: 1, systemWatts: 20) { 1e6 }
        #expect(implausible.components?.isMeasured(.cpu) == false)
    }

    @Test func returnsNothingWithoutChannelsOrInterval() {
        var analyzer = Self.analyzer()
        let empty = analyzer.analyze([], interval: 1, systemWatts: nil) { nil }
        #expect(empty.components == nil)
        let instant = analyzer.analyze(Self.liveInterval, interval: 0, systemWatts: nil) { nil }
        #expect(instant.components == nil)
    }

    @Test func attachesGPUActivityByRegistryID() {
        func gpu(_ id: UInt64) -> GPUSample {
            GPUSample(registryID: id, name: "GPU", coreCount: 20, deviceUtilization: 0, rendererUtilization: nil,
                      tilerUtilization: nil, memoryInUse: nil, memoryAllocated: nil)
        }
        let activity = GPUActivity(activeResidency: 0.5, frequencyMHz: 1000)
        #expect(GPUActivity.merge([gpu(7)], [7: activity]).first?.frequencyMHz == 1000)
        #expect(GPUActivity.merge([gpu(7)], [8: activity]).first?.activeResidency == 0.5, "one GPU, one channel")
        let two = GPUActivity.merge([gpu(7), gpu(9)], [8: activity])
        #expect(two.allSatisfy { $0.frequencyMHz == nil && $0.activeResidency == nil })
    }

    @Test func encodesSourcesAsAnObject() throws {
        let components = PowerComponents(cpu: 1, gpu: 2, ane: 0, dram: nil, clusters: [], sources: [.cpu: .smc])
        let json = try #require(String(data: try JSONEncoder().encode(components), encoding: .utf8))
        #expect(json.contains(#""sources":{"cpu":"smc"}"#))
        let decoded = try JSONDecoder().decode(PowerComponents.self, from: Data(json.utf8))
        #expect(decoded.sources == [.cpu: .smc])
        #expect(decoded.total == 3)
    }
}
