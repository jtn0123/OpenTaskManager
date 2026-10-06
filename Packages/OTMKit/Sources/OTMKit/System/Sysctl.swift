import Darwin

/// Thin wrappers over `sysctlbyname`. Every read returns `nil` instead of
/// throwing because a missing key is normal across Mac generations.
enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; the kernel writes only `size` bytes.
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func value<T>(_ name: String, as _: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    /// Reads a MIB-addressed sysctl into a byte buffer (used for KERN_PROCARGS2
    /// and NET_RT_IFLIST2, whose payloads are variable length).
    static func bytes(_ mib: [Int32]) -> [UInt8]? {
        var mib = mib
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }
}

enum MachTime {
    /// Multiplier from Mach absolute time units to nanoseconds. On Apple
    /// silicon one tick is 125/3 ns; on Intel it is 1 ns.
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }
}
