import Darwin
import Foundation

/// Samples every process on the system.
///
/// Processes owned by the current user are read natively through libproc,
/// which gives footprint, energy, disk I/O, per-tier CPU time and Neural
/// Engine memory. macOS only lets root read those for other users'
/// processes, so for those we fall back to the setuid `ps` binary for CPU
/// time, resident size and thread counts.
final class ProcessSampler {
    var includeRestricted = true

    private struct Tick {
        let interval: TimeInterval
        let gpuTime: [Int32: UInt64]
        let restrictedLive: Bool
    }

    private struct Key: Hashable {
        let pid: Int32
        let start: Int64
    }

    private struct Lasting {
        /// Nil until the path has been read; macOS won't give some.
        let path: String?
        let name: String?
        let responsiblePID: Int32
    }

    private struct Counters {
        let cpuSeconds: Double
        let topTierSeconds: Double?
        let energyNanojoules: UInt64?
        let diskRead: UInt64
        let diskWrite: UInt64
        let wakeups: UInt64?
        let gpuNanoseconds: UInt64?
    }

    private var previous: [Key: Counters] = [:]
    /// What a process keeps for its life, read once rather than every tick:
    /// its executable's path and name, and the process responsible for it.
    private var lasting: [Key: Lasting] = [:]
    private var userNames: [UInt32: String] = [:]
    private var restrictedCadence = SamplingCadence(primingReads: 2)
    /// `ps -M` lists one line per thread, too much output to parse every
    /// tick, so thread counts stay at most every 5 s, live or not.
    private var threadCadence = SamplingCadence()
    private var restrictedCache = RestrictedProcessCache()
    private lazy var supportsV6: Bool = {
        var usage = rusage_info_v6()
        return Self.rusage(getpid(), &usage, flavor: RUSAGE_INFO_V6)
    }()

    func sample(interval: TimeInterval, gpuTime: [Int32: UInt64], restrictedLive: Bool = true) -> [ProcessSample] {
        let kernelList = Self.listProcesses()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(kernelList.count)
        var current: [Key: Counters] = [:]
        var restricted: [Int] = []

        for (index, info) in kernelList.enumerated() {
            let key = Key(pid: info.pid, start: info.startMicroseconds)
            guard let native = readNative(info.pid) else {
                restricted.append(index)
                continue
            }
            let counters = Counters(
                cpuSeconds: native.cpuSeconds,
                topTierSeconds: native.topTierSeconds,
                energyNanojoules: native.energyNanojoules,
                diskRead: native.diskRead,
                diskWrite: native.diskWrite,
                wakeups: native.wakeups,
                gpuNanoseconds: gpuTime[info.pid]
            )
            current[key] = counters
            let before = previous[key]

            var sample = makeSample(info, key: key, restricted: false)
            sample.cpuTime = native.cpuSeconds
            sample.memory = native.footprint
            sample.residentMemory = native.resident
            sample.threadCount = native.threads
            sample.diskReadTotal = native.diskRead
            sample.diskWriteTotal = native.diskWrite
            sample.neuralMemory = native.neuralMemory
            sample.neuralMemoryPeak = native.neuralMemoryPeak
            if native.running, sample.state == .sleeping { sample.state = .running }
            apply(counters, before: before, interval: interval, to: &sample)
            samples.append(sample)
        }

        if includeRestricted, !restricted.isEmpty {
            appendRestricted(kernelList, indices: restricted, tick: Tick(interval: interval, gpuTime: gpuTime, restrictedLive: restrictedLive),
                             current: &current, samples: &samples)
        } else {
            restrictedCache = RestrictedProcessCache()
            restrictedCadence = SamplingCadence(primingReads: 2)
        }

        previous = current
        lasting = lasting.filter { current[$0.key] != nil }
        return samples
    }

    // MARK: - Rates

    private func apply(_ now: Counters, before: Counters?, interval: TimeInterval, to sample: inout ProcessSample) {
        if let gpu = now.gpuNanoseconds { sample.gpuTime = Double(gpu) / 1_000_000_000 }
        guard let before, interval > 0 else { return }

        let cpuDelta = max(now.cpuSeconds - before.cpuSeconds, 0)
        sample.cpuPercent = cpuDelta / interval * 100
        if now.diskRead >= before.diskRead {
            sample.diskReadRate = Double(now.diskRead - before.diskRead) / interval
        }
        if now.diskWrite >= before.diskWrite {
            sample.diskWriteRate = Double(now.diskWrite - before.diskWrite) / interval
        }
        if let energy = now.energyNanojoules, let old = before.energyNanojoules, energy >= old {
            sample.powerWatts = Double(energy - old) / 1_000_000_000 / interval
        }
        if let top = now.topTierSeconds, let old = before.topTierSeconds, cpuDelta > 0 {
            sample.topTierShare = min(max((top - old) / cpuDelta, 0), 1)
        }
        if let wakeups = now.wakeups, let old = before.wakeups, wakeups >= old {
            sample.wakeupsPerSecond = Double(wakeups - old) / interval
        }
        if let gpu = now.gpuNanoseconds {
            let old = before.gpuNanoseconds ?? gpu
            if gpu >= old {
                sample.gpuFraction = min(Double(gpu - old) / 1_000_000_000 / interval, 1)
            }
        }
    }

    // MARK: - Building samples

    private func makeSample(_ info: KernelProcess, key: Key, restricted: Bool) -> ProcessSample {
        let known = lastingFacts(for: key)
        let name = known.name ?? Self.shortName(info.pid) ?? info.command
        return ProcessSample(
            pid: info.pid,
            parentPID: info.parentPID,
            responsiblePID: known.responsiblePID,
            uid: info.uid,
            userName: userName(for: info.uid),
            name: info.pid == 0 ? "kernel_task" : name,
            executablePath: known.path,
            state: info.state,
            nice: info.nice,
            startTime: ProcessIdentity.startTime(microseconds: info.startMicroseconds),
            isTranslated: info.isTranslated,
            isRestricted: restricted,
            cpuPercent: 0,
            cpuTime: 0,
            memory: 0,
            residentMemory: 0,
            threadCount: 0,
            diskReadRate: 0,
            diskWriteRate: 0,
            diskReadTotal: 0,
            diskWriteTotal: 0
        )
    }

    /// A path that can't be read is tried again next tick, as before, and the
    /// name then comes from `proc_name`, which can change on exec.
    private func lastingFacts(for key: Key) -> Lasting {
        if let cached = lasting[key], cached.path != nil { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(key.pid, &buffer, UInt32(buffer.count)) > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
        let facts = Lasting(path: path, name: path.map { ($0 as NSString).lastPathComponent },
                            responsiblePID: lasting[key]?.responsiblePID ?? Responsibility.responsiblePID(for: key.pid))
        lasting[key] = facts
        return facts
    }

    private func userName(for uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    /// The figures' walk keeps the live cadence; the thread walk rides along
    /// on one of its reads at most every 5 s. The native process list still
    /// tells us about exits each tick, so held rows never keep an ended
    /// process alive.
    private func appendRestricted(_ list: [KernelProcess], indices: [Int], tick: Tick,
                                  current: inout [Key: Counters], samples: inout [ProcessSample]) {
        let time = ProcessInfo.processInfo.systemUptime
        let reads = restrictedCadence.shouldRead(at: time, live: tick.restrictedLive)
        let fallback = reads ? PSReader.read() : [:]
        let threads = reads && threadCadence.shouldRead(at: time, live: false) ? PSReader.readThreadCounts() : [:]
        var identities: Set<ProcessIdentity> = []
        for index in indices {
            let info = list[index]
            let key = Key(pid: info.pid, start: info.startMicroseconds)
            var sample = makeSample(info, key: key, restricted: true)
            identities.insert(sample.identity)
            if reads { restrictedCache.update(sample.identity, row: fallback[info.pid], threads: threads[info.pid], at: time) }
            if let row = restrictedCache.reading(for: sample.identity) {
                let counters = Counters(cpuSeconds: row.cpuSeconds, topTierSeconds: nil, energyNanojoules: nil,
                                        diskRead: 0, diskWrite: 0, wakeups: nil, gpuNanoseconds: tick.gpuTime[info.pid])
                current[key] = counters
                sample.cpuTime = row.cpuSeconds
                sample.memory = row.residentBytes
                sample.residentMemory = row.residentBytes
                sample.threadCount = row.threads
                if let state = row.state, sample.state != .zombie { sample.state = state }
                // GPU counters still arrive each tick. CPU uses ps's own interval.
                apply(counters, before: previous[key], interval: tick.interval, to: &sample)
                sample.cpuPercent = row.cpuPercent
            }
            samples.append(sample)
        }
        restrictedCache.retain(identities)
    }

    // MARK: - Native reads

    private struct Native {
        let cpuSeconds: Double
        let topTierSeconds: Double?
        let footprint: UInt64
        let resident: UInt64
        let threads: Int
        let running: Bool
        let diskRead: UInt64
        let diskWrite: UInt64
        let energyNanojoules: UInt64?
        let wakeups: UInt64?
        var neuralMemory: UInt64?
        var neuralMemoryPeak: UInt64?
    }

    private func readNative(_ pid: Int32) -> Native? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }

        if supportsV6 {
            var usage = rusage_info_v6()
            guard Self.rusage(pid, &usage, flavor: RUSAGE_INFO_V6) else { return nil }
            // The Neural Engine figures come with the same call; before
            // macOS 15 their fields are reserved and read 0, which isn't a figure.
            let neural = ProcessSample.systemReportsNeuralMemory
            return Native(
                cpuSeconds: MachTime.seconds(fromTicks: usage.ri_user_time + usage.ri_system_time),
                topTierSeconds: MachTime.seconds(fromTicks: usage.ri_user_ptime + usage.ri_system_ptime),
                footprint: usage.ri_phys_footprint,
                resident: task.pti_resident_size,
                threads: Int(task.pti_threadnum),
                running: task.pti_numrunning > 0,
                diskRead: usage.ri_diskio_bytesread,
                diskWrite: usage.ri_diskio_byteswritten,
                energyNanojoules: usage.ri_energy_nj > 0 ? usage.ri_energy_nj : nil,
                wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups,
                neuralMemory: neural ? usage.ri_neural_footprint : nil,
                neuralMemoryPeak: neural ? usage.ri_lifetime_max_neural_footprint : nil
            )
        }

        var usage = rusage_info_v4()
        guard Self.rusage(pid, &usage, flavor: RUSAGE_INFO_V4) else { return nil }
        return Native(
            cpuSeconds: MachTime.seconds(fromTicks: usage.ri_user_time + usage.ri_system_time),
            topTierSeconds: nil,
            footprint: usage.ri_phys_footprint,
            resident: task.pti_resident_size,
            threads: Int(task.pti_threadnum),
            running: task.pti_numrunning > 0,
            diskRead: usage.ri_diskio_bytesread,
            diskWrite: usage.ri_diskio_byteswritten,
            energyNanojoules: nil,
            wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
        )
    }

    private static func rusage<T>(_ pid: Int32, _ usage: inout T, flavor: Int32) -> Bool {
        withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, flavor, $0) == 0
            }
        }
    }

    private static func shortName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    // MARK: - Kernel process list

    struct KernelProcess {
        let pid: Int32
        let parentPID: Int32
        let uid: UInt32
        let command: String
        let state: ProcessState
        let nice: Int32
        let startMicroseconds: Int64
        let isTranslated: Bool
    }

    /// One sysctl that returns every process, including ones we cannot inspect.
    static func listProcesses() -> [KernelProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var processes: [kinfo_proc] = []
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            // Processes can spawn between the two calls; leave headroom.
            size += size / 8
            processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = processes.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result == 0 {
                processes.removeLast(processes.count - size / MemoryLayout<kinfo_proc>.stride)
                break
            }
            guard errno == ENOMEM else { return [] }
        }

        return processes.map { process in
            let proc = process.kp_proc
            let start = proc.p_un.__p_starttime
            let command = withUnsafeBytes(of: proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return KernelProcess(
                pid: proc.p_pid,
                parentPID: process.kp_eproc.e_ppid,
                uid: process.kp_eproc.e_ucred.cr_uid,
                command: command,
                state: state(fromKernel: proc.p_stat),
                nice: Int32(proc.p_nice),
                startMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec),
                isTranslated: proc.p_flag & translatedFlag != 0
            )
        }
    }

    /// `P_TRANSLATED` from <sys/proc.h>: the process runs under Rosetta.
    private static let translatedFlag: Int32 = 0x0002_0000

    private static func state(fromKernel status: CChar) -> ProcessState {
        switch Int32(status) {
        case SIDL: .idle
        case SRUN, SSLEEP: .sleeping
        case SSTOP: .stopped
        case SZOMB: .zombie
        default: .unknown
        }
    }
}

/// Wraps the private-but-stable `responsibility_get_pid_responsible_for_pid`,
/// which Activity Monitor uses to attribute helpers to their app.
enum Responsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private static let lookup: Lookup? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func responsiblePID(for pid: Int32) -> Int32 {
        guard pid > 0, let lookup else { return pid }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : pid
    }
}
