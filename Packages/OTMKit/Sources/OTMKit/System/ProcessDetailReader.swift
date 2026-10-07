import Darwin
import Foundation

/// Reads one process's counters and threads for its inspector and `otm
/// inspect` / `otm threads`: a few libproc calls for the one process, never
/// the whole list. macOS answers them for the caller's own processes only;
/// for anyone else's they fail with EPERM unless run as root.
public enum ProcessDetailReader {
    /// `PROC_PIDLISTTHREADIDS` from <sys/proc_info.h>: the 64-bit IDs of a
    /// process's threads, which `PROC_PIDTHREADID64INFO` reads by. xnu's
    /// proc_info.c answers it, though the SDK's header leaves the flavor out.
    /// The public `PROC_PIDLISTTHREADS` gives pthread addresses instead,
    /// which are reused as threads come and go.
    static let listThreadIDs: Int32 = 28

    /// The process that has `pid` now, from the kernel's process table, which
    /// anyone may read. nil when there's no such process.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startTime: ProcessIdentity.startTime(microseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)))
    }

    /// Counters for the process, checked against its start time: a PID taken
    /// over by a later process reads as `.unavailable`, never as the newcomer's.
    public static func diagnostics(_ identity: ProcessIdentity, at time: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> ProcessDiagnostics {
        var all = proc_taskallinfo()
        switch taskInfo(identity, into: &all) {
        case let .failure(failure): return .unreadable(identity, at: time, because: failure)
        case .success: break
        }
        let task = all.ptinfo
        var usage = rusage_info_v4()
        let hasUsage = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(identity.pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        let usageFailure = hasUsage ? nil : ProcessReadFailure(errno: errno)
        func fromUsage<T>(_ value: @autoclosure () -> T) -> ProcessField<T> {
            guard let usageFailure else { return .value(value()) }
            return usageFailure == .denied ? .denied : .unavailable
        }
        return ProcessDiagnostics(
            identity: identity,
            time: time,
            footprint: fromUsage(usage.ri_phys_footprint),
            // The kernel raises its high-water mark lazily, so it can trail
            // the footprint just read; the peak is at least that.
            peakFootprint: fromUsage(max(usage.ri_lifetime_max_phys_footprint, usage.ri_phys_footprint)),
            resident: .value(task.pti_resident_size),
            faults: .value(count(task.pti_faults)),
            pageIns: fromUsage(usage.ri_pageins),
            copyOnWriteFaults: .value(count(task.pti_cow_faults)),
            contextSwitches: .value(count(task.pti_csw)),
            systemCalls: .value(count(task.pti_syscalls_mach) + count(task.pti_syscalls_unix)),
            messages: .value(count(task.pti_messages_sent) + count(task.pti_messages_received)),
            basePriority: .value(task.pti_priority),
            policy: .value(SchedulingPolicy(kernelValue: task.pti_policy)),
            runningThreads: .value(Int(task.pti_numrunning)),
            qos: fromUsage(QoSShare.shares(qosSeconds(usage)))
        )
    }

    /// Every thread of the process, with its CPU time, state and priority.
    public static func threads(_ identity: ProcessIdentity) -> Result<[ThreadSample], ProcessReadFailure> {
        var all = proc_taskallinfo()
        if case let .failure(failure) = taskInfo(identity, into: &all) { return .failure(failure) }
        // Room for threads started since the count, and a retry if it was short.
        var capacity = Int(all.ptinfo.pti_threadnum) + 32
        for _ in 0..<4 {
            var ids = [UInt64](repeating: 0, count: capacity)
            let bytes = ids.withUnsafeMutableBytes { proc_pidinfo(identity.pid, listThreadIDs, 0, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { return .failure(ProcessReadFailure(errno: errno)) }
            let count = Int(bytes) / MemoryLayout<UInt64>.stride
            if count == capacity {
                capacity *= 2
                continue
            }
            // A thread that ends between the list and its read is left out.
            return .success(ids.prefix(count).compactMap { thread(identity.pid, id: $0) })
        }
        return .failure(.unavailable)
    }

    private static func thread(_ pid: Int32, id: UInt64) -> ThreadSample? {
        var info = proc_threadinfo()
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTHREADID64INFO, id, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ThreadSample(
            id: id,
            name: name.isEmpty ? nil : name,
            userTime: Double(info.pth_user_time) / 1_000_000_000,
            systemTime: Double(info.pth_system_time) / 1_000_000_000,
            state: ThreadRunState(kernelValue: info.pth_run_state),
            priority: info.pth_curpri,
            basePriority: info.pth_priority,
            policy: SchedulingPolicy(kernelValue: info.pth_policy)
        )
    }

    /// The task and BSD info in one call, after checking the process is
    /// still the one that started when `identity` says.
    private static func taskInfo(_ identity: ProcessIdentity, into all: inout proc_taskallinfo) -> Result<Void, ProcessReadFailure> {
        // The kernel's own task isn't readable, even by its owner.
        guard identity.pid > 0 else { return .failure(.denied) }
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTASKALLINFO, 0, &all, size) == size else {
            return .failure(ProcessReadFailure(errno: errno))
        }
        let start = ProcessIdentity.startTime(microseconds: Int64(all.pbsd.pbi_start_tvsec) * 1_000_000 + Int64(all.pbsd.pbi_start_tvusec))
        return start == identity.startTime ? .success(()) : .failure(.ended)
    }

    /// proc_taskinfo's counters are 32-bit and signed, so a busy process's
    /// pass 2^31 and read negative; as unsigned they last to 2^32.
    private static func count(_ counter: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: counter))
    }

    private static func qosSeconds(_ usage: rusage_info_v4) -> [QoSClass: Double] {
        [
            .userInteractive: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_user_interactive),
            .userInitiated: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_user_initiated),
            .default: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_default),
            .utility: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_utility),
            .background: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_background),
            .maintenance: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_maintenance),
            .legacy: MachTime.seconds(fromTicks: usage.ri_cpu_time_qos_legacy),
        ]
    }
}
