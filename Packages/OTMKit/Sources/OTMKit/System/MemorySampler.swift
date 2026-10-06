import Darwin

final class MemorySampler {
    private let host = mach_host_self()
    private let physical = UInt64(Sysctl.int("hw.memsize") ?? 0)
    private let pageSize = UInt64(Sysctl.int("hw.pagesize") ?? Int(getpagesize()))

    func sample() -> MemorySample {
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
            return MemorySample(
                physical: physical, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: physical,
                swapUsed: swap?.xsu_used ?? 0, swapTotal: swap?.xsu_total ?? 0, pressure: pressure,
                availablePercent: Sysctl.int("kern.memorystatus_level"), pageIns: 0, pageOuts: 0, swapIns: 0, swapOuts: 0
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
            pageIns: stats.pageins,
            pageOuts: stats.pageouts,
            swapIns: stats.swapins,
            swapOuts: stats.swapouts
        )
    }
}
