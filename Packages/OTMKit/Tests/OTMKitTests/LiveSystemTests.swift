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
    }

    @Test func cpuPercentTracksBusyWork() async throws {
        let monitor = SystemMonitor()
        _ = await monitor.sample()
        let deadline = Date().addingTimeInterval(0.4)
        var counter = 0
        while Date() < deadline { counter &+= 1 }
        let snapshot = await monitor.sample()
        let me = try #require(snapshot.processes.first { $0.pid == getpid() })
        #expect(me.cpuPercent > 30, "spinning for 0.4 s should register at least 30% of a core, got \(me.cpuPercent)")
        #expect(counter > 0)
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
        defer { if child.isRunning { child.terminate() } }

        try ProcessControl.send(.stop, to: pid)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ProcessSampler.listProcesses().first { $0.pid == pid }?.state == .stopped)

        try ProcessControl.send(.continue, to: pid)
        try ProcessControl.send(.terminate, to: pid)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test func signallingLaunchdIsDenied() {
        #expect(throws: ProcessControlError.permissionDenied) {
            try ProcessControl.send(.continue, to: 1)
        }
    }
}
