import Darwin

/// Cumulative paging counters from `vm_statistics64`, all in pages.
struct PagingCounters: Equatable {
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0
    var compressions: UInt64 = 0
    var decompressions: UInt64 = 0
}

/// Per-second paging rates in bytes.
struct PagingRates: Equatable {
    var pageIn = 0.0
    var pageOut = 0.0
    var swapIn = 0.0
    var swapOut = 0.0
    var compression = 0.0
    var decompression = 0.0

    /// Rates between two readings of the cumulative counters. Without a
    /// previous reading or a positive interval every rate is 0, and a counter
    /// that went backwards (a reset) counts as 0 rather than a huge spike.
    static func between(_ previous: PagingCounters?, _ current: PagingCounters, interval: Double, pageSize: UInt64) -> Self {
        guard let previous, interval > 0, interval.isFinite else { return Self() }
        func rate(_ now: UInt64, _ before: UInt64) -> Double {
            now >= before ? Double(now - before) * Double(pageSize) / interval : 0
        }
        return Self(
            pageIn: rate(current.pageIns, previous.pageIns),
            pageOut: rate(current.pageOuts, previous.pageOuts),
            swapIn: rate(current.swapIns, previous.swapIns),
            swapOut: rate(current.swapOuts, previous.swapOuts),
            compression: rate(current.compressions, previous.compressions),
            decompression: rate(current.decompressions, previous.decompressions)
        )
    }
}

final class MemorySampler {
    private let host = mach_host_self()
    private let physical = UInt64(Sysctl.int("hw.memsize") ?? 0)
    private let pageSize = UInt64(Sysctl.int("hw.pagesize") ?? Int(getpagesize()))
    private var previousCounters: PagingCounters?

    func sample(interval: Double) -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }

        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self)
        let pressure: MemoryPressure = switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 4: .critical
        case 2: .warning
        default: .normal
        }

        guard result == KERN_SUCCESS else {
            previousCounters = nil
            return MemorySample(
                physical: physical, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: physical,
                swapUsed: swap?.xsu_used ?? 0, swapTotal: swap?.xsu_total ?? 0, pressure: pressure,
                availablePercent: Sysctl.int("kern.memorystatus_level"), pageIns: 0, pageOuts: 0, swapIns: 0, swapOuts: 0,
                pageInRate: 0, pageOutRate: 0, swapInRate: 0, swapOutRate: 0, compressionRate: 0, decompressionRate: 0
            )
        }

        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        // Same arithmetic Activity Monitor uses for its memory breakdown.
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = app + wired + compressed
        let free = physical > used + cached ? physical - used - cached : 0

        let counters = PagingCounters(
            pageIns: stats.pageins, pageOuts: stats.pageouts, swapIns: stats.swapins, swapOuts: stats.swapouts,
            compressions: stats.compressions, decompressions: stats.decompressions
        )
        let rates = PagingRates.between(previousCounters, counters, interval: interval, pageSize: page)
        previousCounters = counters

        return MemorySample(
            physical: physical,
            used: used,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free,
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressure: pressure,
            availablePercent: Sysctl.int("kern.memorystatus_level"),
            pageIns: counters.pageIns,
            pageOuts: counters.pageOuts,
            swapIns: counters.swapIns,
            swapOuts: counters.swapOuts,
            pageInRate: rates.pageIn,
            pageOutRate: rates.pageOut,
            swapInRate: rates.swapIn,
            swapOutRate: rates.swapOut,
            compressionRate: rates.compression,
            decompressionRate: rates.decompression
        )
    }
}
