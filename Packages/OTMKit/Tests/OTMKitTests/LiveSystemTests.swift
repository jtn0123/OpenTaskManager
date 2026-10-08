import Darwin
import Foundation
@testable import OTMKit
import Testing

/// These tests read the real machine, so they assert invariants rather than
/// exact values.
@Suite(.serialized)
struct LiveSystemTests {
    @Test func topologyIsConsistent() {
        let topology = CPUTopologyReader.read()
        #expect(topology.logicalCores == ProcessInfo.processInfo.processorCount)
        #expect(topology.tierForCPU.count == topology.logicalCores)
        #expect(topology.tiers.reduce(0) { $0 + $1.logicalCPUs } == topology.logicalCores)
        let levels = Set(topology.tiers.map(\.level))
        #expect(topology.tierForCPU.allSatisfy { levels.contains($0) })
    }

    @Test func snapshotDescribesThisMac() async throws {
        let monitor = SystemMonitor()
        let snapshot = try await monitor.measuredSample(over: .milliseconds(300))

        #expect(snapshot.interval > 0.2)
        #expect(snapshot.uptime > 0)
        #expect(snapshot.cpu.coreUsage.count == monitor.topology.logicalCores)
        #expect((0...1).contains(snapshot.cpu.usage))
        #expect(snapshot.memory.physical > 0)
        #expect(snapshot.memory.used <= snapshot.memory.physical)
        let memory = snapshot.memory
        let rates = [memory.pageInRate, memory.pageOutRate, memory.swapInRate, memory.swapOutRate,
                     memory.compressionRate, memory.decompressionRate]
        #expect(rates.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(snapshot.network.contains { $0.kind == .loopback })
        #expect(snapshot.volumes.contains { $0.isRoot })
        // The startup volume sits on one of the disks being sampled.
        let disks = Set(snapshot.disks.map(\.bsdName))
        if let root = snapshot.volumes.first(where: \.isRoot), let disk = root.physicalDisk {
            #expect(disks.contains(disk))
        }
    }

    /// CI runs in a VM that may have no SMC, battery or adapter, so these
    /// checks only apply to the readings that exist.
    @Test func powerReadingsAreSane() async throws {
        if let smc = SMCConnection() {
            if let total = smc.double("PSTR") { #expect(total.isFinite && total >= 0) }
            #expect(smc.double("ZZZZ") == nil)
            #expect(smc.double("ZZZZ") == nil, "a missing key stays missing once cached")
        }

        let monitor = SystemMonitor()
        let power = try await monitor.measuredSample(over: .milliseconds(300)).power
        if let watts = power.systemWatts {
            #expect(watts.isFinite && watts > 0)
            #expect(power.systemWattsSource != nil)
        } else {
            #expect(power.systemWattsSource == nil)
        }
        if let adapter = power.adapter {
            #expect(adapter.ratedWatts.map { $0.isFinite && $0 > 0 } ?? true)
            #expect(adapter.inputWatts.map { $0.isFinite && $0 >= 0 } ?? true)
            #expect(adapter.batteryWatts.map(\.isFinite) ?? true)
            #expect(power.battery?.isPluggedIn ?? true)
        }
    }

    /// IOReport and its power channels may be missing (CI VMs, Intel), so
    /// only check what this Mac reports.
    @Test func componentPowerIsSane() async throws {
        let monitor = SystemMonitor()
        let first = await monitor.sample()
        #expect(first.power.components == nil, "the first sample has no interval")
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await monitor.sample()

        if let components = snapshot.power.components {
            let limit = SoCPowerAnalyzer.limitWatts(systemWatts: snapshot.power.systemWatts)
            for component in PowerComponent.allCases {
                if let watts = components.watts(component) {
                    #expect(watts.isFinite && watts >= 0 && watts <= limit, "\(component): \(watts) W")
                }
            }
            #expect(components.total.isFinite)
            let levels = Set(monitor.topology.tiers.map(\.level))
            #expect(Set(components.clusters.map(\.id)).count == components.clusters.count)
            let order = components.clusters.map { $0.tierLevel ?? .max }
            #expect(order == order.sorted())
            for cluster in components.clusters {
                #expect(cluster.tierLevel.map(levels.contains) ?? true)
                #expect(cluster.activeFraction.map { (0...1).contains($0) } ?? true)
                #expect(cluster.frequencyMHz.map { (100...10_000).contains($0) } ?? true)
                #expect(cluster.watts.map { $0.isFinite && $0 >= 0 } ?? true)
            }
        }
        for gpu in snapshot.gpus {
            #expect(gpu.activeResidency.map { (0...1).contains($0) } ?? true)
            #expect(gpu.frequencyMHz.map { (100...10_000).contains($0) } ?? true)
        }
    }

    /// A virtual machine's GPU doesn't report its load and its kernel counts
    /// no energy per process; real Apple silicon does both, and must keep
    /// showing them as measured.
    @Test func appleSiliconReportsGPULoadAndProcessEnergy() async throws {
        let monitor = SystemMonitor()
        let snapshot = try await monitor.measuredSample(over: .milliseconds(300))
        #expect(snapshot.measuresProcessEnergy != nil, "a second sample can always tell")
        for gpu in snapshot.gpus {
            #expect(gpu.deviceUtilization.map { (0...1).contains($0) } ?? true)
        }
        guard monitor.topology.isAppleSilicon, Sysctl.int("kern.hv_vmm_present") != 1 else { return }
        #expect(snapshot.gpus.contains { $0.deviceUtilization != nil })
        #expect(snapshot.measuresProcessEnergy == true)
    }

    @Test func processListIncludesSelfAndSystemProcesses() async throws {
        let monitor = SystemMonitor()
        let snapshot = try await monitor.measuredSample(over: .milliseconds(300))
        let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        let me = try #require(byPID[getpid()])
        #expect(!me.isRestricted)
        #expect(me.memory > 0)
        #expect(me.threadCount > 0)
        #expect(me.cpuTime > 0)
        #expect(me.userName == NSUserName())
        #expect(me.executablePath != nil)

        // launchd is root-owned; we only see it through the ps fallback.
        let launchd = try #require(byPID[1])
        #expect(launchd.name == "launchd")
        #expect(launchd.uid == 0)
        #expect(launchd.isRestricted)
        #expect(launchd.memory > 0)
        #expect(launchd.cpuTime > 0)

        // Neural Engine memory comes with the same read as the footprint, from
        // macOS 15; it's unknown, not 0, where macOS doesn't say.
        #expect((me.neuralMemory != nil) == ProcessSample.systemReportsNeuralMemory)
        #expect((me.neuralMemoryPeak ?? 0) >= (me.neuralMemory ?? 0), "now can't be above the peak")
        #expect(launchd.neuralMemory == nil, "restricted processes have no figure")
    }

    /// The loop spins until its own thread has used 0.3 s of CPU, however long
    /// the Mac's load makes that take, and the check is on CPU time: never on
    /// the share of a core the loop happened to get.
    @Test func cpuPercentTracksBusyWork() async throws {
        let monitor = SystemMonitor()
        let processBefore = Self.processCPUSeconds()
        _ = await monitor.sample()
        let busy = Self.spin(cpuSeconds: 0.3)
        let snapshot = await monitor.sample()
        let process = Self.processCPUSeconds() - processBefore
        let me = try #require(snapshot.processes.first { $0.pid == getpid() })

        // The percent is CPU time over the sampler's interval. That time takes in
        // all of the loop's, which ran between the two reads, and no more than
        // the whole process used around them. 1 ms covers the clocks' rounding.
        let used = me.cpuPercent / 100 * snapshot.interval
        #expect(used >= busy - 0.001, "the loop used \(busy) s of CPU, but \(me.cpuPercent)% over \(snapshot.interval) s is \(used) s")
        #expect(used <= process + 0.001, "the process used \(process) s of CPU in all, but \(me.cpuPercent)% is \(used) s")
    }

    /// Spins until this thread has used `cpuSeconds` of CPU, and returns how much it used.
    private static func spin(cpuSeconds: Double) -> Double {
        let start = threadCPUSeconds()
        var used = 0.0
        while used < cpuSeconds { used = threadCPUSeconds() - start }
        return used
    }

    private static func threadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    /// The process's CPU time, every thread's, from `getrusage` rather than
    /// the sampler's own read.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec
        return Double(seconds) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    @Test func inspectsOwnArgumentsAndOpenFiles() throws {
        let arguments = try #require(ProcessInspector.arguments(of: getpid()))
        #expect(!arguments.executable.isEmpty)
        #expect(!arguments.arguments.isEmpty)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("otm-open-\(getpid()).txt").path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let fd = open(path, O_RDONLY)
        defer { close(fd); unlink(path) }

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)

        let files = try #require(ProcessInspector.openFiles(of: getpid()))
        // The kernel reports the canonical path (/private/var/…); Foundation's
        // resolvingSymlinksInPath strips /private, so ask realpath instead.
        let resolved = try #require(realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(files.contains { $0.descriptor == fd && $0.detail == resolved && $0.kind == .file })
        let socketEntry = try #require(files.first { $0.descriptor == listener })
        #expect(socketEntry.socket?.proto == .tcp)
        #expect(socketEntry.socket?.state == "LISTEN")
        #expect(socketEntry.socket?.localAddress == "127.0.0.1")
        #expect(socketEntry.socket?.localPort != nil)
    }

    @Test func signalsSuspendResumeAndTerminateAChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        // SIGKILL, since SIGTERM would sit pending if the child is still stopped.
        defer { if child.isRunning { kill(pid, SIGKILL) } }

        try ProcessControl.send(.stop, to: pid)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ProcessSampler.listProcesses().first { $0.pid == pid }?.state == .stopped)

        try ProcessControl.send(.continue, to: pid)
        try ProcessControl.send(.terminate, to: pid)
        // Poll rather than block in waitUntilExit(), which once hung the suite
        // on a Swift concurrency thread: a missed exit fails here instead.
        let deadline = ContinuousClock.now + .seconds(5)
        while child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!child.isRunning, "/bin/sleep was still running 5 s after SIGTERM")
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test func signallingLaunchdIsDenied() {
        #expect(throws: ProcessControlError.permissionDenied) {
            try ProcessControl.send(.continue, to: 1)
        }
    }
}
