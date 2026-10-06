import Foundation
import IOKit

/// Per-component power, CPU cluster clocks and GPU residency from IOReport.
/// Subscribes once; each `sample` reads the change since the previous one.
final class SoCPowerSampler {
    private let subscription: IOReportSubscription
    private var analyzer: SoCPowerAnalyzer

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
    func sample(systemWatts: Double?, smcCPUWatts: () -> Double?) -> SoCPowerResult? {
        guard let reading = subscription.sample() else { return nil }
        return analyzer.analyze(reading.channels, interval: reading.interval, systemWatts: systemWatts, smcCPUWatts: smcCPUWatts)
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
        var tables: [UInt64: [Double]] = [:]
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(accelerator, &registryID)
            guard let parent = IORegistry.parent(of: accelerator) else { return }
            defer { IOObjectRelease(parent) }
            guard let data = IORegistry.property("perf-states", of: parent) as? Data else { return }
            // The property can hold several tables back to back; the count says
            // how long the first one is.
            let count = (IORegistry.property("perf-state-count", of: parent) as? Data).flatMap { data -> Int? in
                data.count >= 4 ? Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) : nil
            }
            if let table = FrequencyTable.megahertz(from: data, limit: count) { tables[registryID] = table }
        }
        return tables
    }
}
