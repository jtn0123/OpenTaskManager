import Foundation
import IOKit

/// Per-component power, CPU cluster clocks and GPU residency from IOReport.
/// Subscribes once; each `sample` reads the change since the previous one.
final class SoCPowerSampler {
    private let subscription: IOReportSubscription
    private var analyzer: SoCPowerAnalyzer
    private let media: IOReportSubscription?
    private var mediaCadence = MediaEngineCadence()
    private var heldMedia: [MediaEngineSample] = []

    /// nil where IOReport or its power channels are missing (Intel Macs, most VMs).
    init?(topology: CPUTopology, levelForClusterType: [String: Int]) {
        guard let library = IOReportLibrary(),
              let subscription = IOReportSubscription(
                  library: library,
                  groups: [
                      (SoCPowerAnalyzer.energyGroup, nil),
                      (SoCPowerAnalyzer.cpuStatesGroup, SoCPowerAnalyzer.cpuStatesSubgroup),
                      (SoCPowerAnalyzer.gpuStatesGroup, SoCPowerAnalyzer.gpuStatesSubgroup),
                  ],
                  keep: SoCPowerAnalyzer.wants
              ) else { return nil }
        self.subscription = subscription
        media = IOReportSubscription(library: library, groups: [(SoCPowerAnalyzer.mediaGroup, SoCPowerAnalyzer.mediaSubgroup)],
                                     keep: SoCPowerAnalyzer.wants)
        analyzer = SoCPowerAnalyzer(
            tiers: topology.tiers,
            levelForClusterType: levelForClusterType,
            cpuTableCandidates: Self.cpuTableCandidates(),
            gpuTables: Self.gpuTables()
        )
    }

    /// Whether the power manager's energy counters were found to update in batches.
    var isEnergyModelBatched: Bool { analyzer.energyModel.isBatched }

    /// nil on the first call, which only sets the baseline.
    func sample(systemWatts: Double?, mediaActivityLive: Bool = false, smcCPUWatts: () -> Double?) -> SoCPowerResult? {
        guard let reading = subscription.sample() else { return nil }
        var result = analyzer.analyze(reading.channels, interval: reading.interval, systemWatts: systemWatts, smcCPUWatts: smcCPUWatts)
        if mediaCadence.shouldRead(at: ProcessInfo.processInfo.systemUptime, live: mediaActivityLive) {
            if let reading = media?.sample() {
                heldMedia = reading.channels.compactMap(MediaEngineChannel.sample).sorted { ($0.rank, $0.channel) < ($1.rank, $1.channel) }
                result.mediaEnginesFresh = true
            }
        }
        result.mediaEngines = heldMedia
        return result
    }

    /// The pmgr node's clock tables for each CPU cluster domain: the plain
    /// `voltage-statesN` table first, then its `-sram` twin.
    private static func cpuTableCandidates() -> [String: [Data]] {
        var properties: [String: Any] = [:]
        IORegistry.forEachService(named: "pmgr") { properties = IORegistry.properties(of: $0) }
        guard let domains = properties["perf-domains"] as? Data else { return [:] }
        var candidates: [String: [Data]] = [:]
        for (name, table) in FrequencyTable.perfDomainTables(domains) where CPUClusterChannel(name) != nil {
            candidates[name] = ["voltage-states\(table)", "voltage-states\(table)-sram"].compactMap { properties[$0] as? Data }
        }
        return candidates
    }

    /// Each GPU's clock per performance state, from the `perf-states` table
    /// of the device-tree node the accelerator hangs off.
    private static func gpuTables() -> [UInt64: [Double]] {
        // IOKit consumes the matching dictionary and services remain live for each property read.
        var tables: [UInt64: [Double]] = [:]
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            var registryID: UInt64 = 0
            unsafe IORegistryEntryGetRegistryEntryID(accelerator, &registryID)
            guard let parent = IORegistry.parent(of: accelerator) else { return }
            defer { IOObjectRelease(parent) }
            guard let data = IORegistry.property("perf-states", of: parent) as? Data else { return }
            // The property can hold several tables back to back; the count says
            // how long the first one is.
            let count = (IORegistry.property("perf-state-count", of: parent) as? Data).flatMap { data -> Int? in
                data.count >= 4 ? Int(UInt32(littleEndian: data.bytes.load(fromByteOffset: 0, as: UInt32.self))) : nil
            }
            if let table = FrequencyTable.megahertz(from: data, limit: count) { tables[registryID] = table }
        }
        return tables
    }
}
