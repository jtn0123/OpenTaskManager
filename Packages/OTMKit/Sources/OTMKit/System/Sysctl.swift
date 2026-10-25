import Darwin

/// Thin wrappers over `sysctlbyname`. Every read returns `nil` instead of
/// throwing because a missing key is normal across Mac generations.
enum Sysctl {
    static func int(_ name: String) -> Int? {
        // The aligned value and size stay live for the call; the kernel receives eight bytes and reports whether it wrote four or eight.
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard unsafe sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; the kernel writes only `size` bytes.
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        // The size query precedes allocation; the kernel receives that capacity and text decoding stays inside the array.
        var size = 0
        guard unsafe sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard unsafe sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func value<T: BitwiseCopyable>(_ name: String, as _: T.Type) -> T? {
        // The allocation is aligned for the requested C record; it is read only after an exact-size write and freed on every path.
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { unsafe pointer.deallocate() }
        guard unsafe sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return unsafe pointer.pointee
    }

    /// Reads a MIB-addressed sysctl into a byte buffer (used for KERN_PROCARGS2
    /// and NET_RT_IFLIST2, whose payloads are variable length).
    static func bytes(_ mib: [Int32]) -> [UInt8]? {
        // Both arrays stay live for sysctl; the size query supplies the output capacity, and the returned prefix is bounded.
        var mib = mib
        var size = 0
        guard unsafe sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard unsafe sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }
}

enum MachTime {
    /// Multiplier from Mach absolute time units to nanoseconds. On Apple
    /// silicon one tick is 125/3 ns; on Intel it is 1 ns.
    static let nanosecondsPerTick: Double = {
        // Mach borrows this aligned local output record only until the call returns.
        var info = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }
}
