@testable import OTMKit
import Testing

struct PSReaderTests {
    @Test(arguments: [
        ("0:00.07", 0.07),
        ("5:56.31", 356.31),
        ("12:03:04.50", 43384.5),
        ("2-01:00:00.00", 176_400.0),
    ])
    func parsesCPUTime(text: String, seconds: Double) throws {
        let parsed = try #require(PSReader.parseCPUTime(text))
        #expect(abs(parsed - seconds) < 0.001)
    }

    @Test func rejectsGarbageCPUTime() {
        #expect(PSReader.parseCPUTime("abc") == nil)
        #expect(PSReader.parseCPUTime("1:2.3.4") == nil)
        #expect(PSReader.parseCPUTime("-1:00.00") == nil)
    }

    /// The byte parser rounds each part exactly as `Double`'s parser does.
    @Test(arguments: ["0:00.07", "59:59.99", "1:23:45.67", "3-04:05:06.78", "0:0.1", "12345678901234567:00.00", "1e2:00"])
    func cpuTimeMatchesDoubleParsing(text: String) throws {
        var days = 0.0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            days = try #require(Double(clock[..<dash]))
            clock = clock[clock.index(after: dash)...]
        }
        let seconds = try clock.split(separator: ":").reduce(0.0) { try $0 * 60 + #require(Double($1)) }
        #expect(PSReader.parseCPUTime(text) == days * 86_400 + seconds)
    }

    @Test func parsesRows() {
        let output = """
            1 Ss     5:56.48  21696
          546 Ss     1:58.15  34720
          999 Z      0:00.00      0
        broken line
        4294967296 S  0:00.00      0
         1000 R      0:01.00     12

        """
        let rows = PSReader.parse(output)
        #expect(rows.count == 4)
        #expect(rows[1000] == PSReader.Row(cpuSeconds: 1, residentBytes: 12 * 1024, state: .running))
        #expect(rows[1] == PSReader.Row(cpuSeconds: 356.48, residentBytes: 21696 * 1024, state: .sleeping))
        #expect(rows[999]?.state == .zombie)
    }

    @Test func countsThreadsFromThreadListing() {
        let output = """
        USER               PID   TT   %CPU STAT PRI     STIME     UTIME COMMAND
        root                 1   ??    0.0 S    31T   0:00.07   0:00.00 /sbin/launchd
                             1         0.1 S    37T   0:00.08   0:00.06
                             1         0.0 S    31T   0:00.00   0:00.00
        root               546   ??    0.0 S    31T   0:00.07   0:00.00 /usr/libexec/logd
        _windowserver      619   ??    1.0 S    79T   0:01.00   0:02.00 /System/WindowServer
                           619         0.0 S    79T   0:00.00   0:00.00
        """
        #expect(PSReader.parseThreadCounts(output) == [1: 3, 546: 1, 619: 2])
    }
}

struct ProcArgsTests {
    private func procArgs(argc: Int32, strings: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(strings[0].utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for string in strings.dropFirst() {
            bytes += Array(string.utf8) + [0]
        }
        return bytes + [0]
    }

    @Test func parsesExecutableArgumentsAndEnvironment() throws {
        let bytes = procArgs(argc: 3, strings: [
            "/usr/bin/python3", "python3", "-m", "http.server",
            "HOME=/Users/me", "PATH=/usr/bin:/bin", "EMPTY=", "WEIRD=a=b",
        ])
        let parsed = try #require(ProcessInspector.parseProcArgs(bytes))
        #expect(parsed.executable == "/usr/bin/python3")
        #expect(parsed.arguments == ["python3", "-m", "http.server"])
        #expect(parsed.environment.map(\.name) == ["HOME", "PATH", "EMPTY", "WEIRD"])
        #expect(parsed.environment.last?.value == "a=b")
        #expect(parsed.commandLine == "python3 -m http.server")
    }

    @Test func rejectsTruncatedBuffer() {
        #expect(ProcessInspector.parseProcArgs([1, 0]) == nil)
    }
}

struct MiscParsingTests {
    @Test func parsesGPUClientCreator() {
        #expect(GPUSampler.pid(fromCreator: "pid 619, WindowServer") == 619)
        #expect(GPUSampler.pid(fromCreator: "pid 7, x") == 7)
        #expect(GPUSampler.pid(fromCreator: "kernel") == nil)
    }

    @Test func readsGPUUtilizationOnlyWhenReported() {
        let appleSilicon: [String: Any] = ["Device Utilization %": 37, "Renderer Utilization %": 35, "In use system memory": 696_729_600]
        #expect(GPUSampler.deviceUtilization(appleSilicon) == 0.37)
        #expect(GPUSampler.deviceUtilization(["Device Utilization %": 0]) == 0, "an idle GPU is a real 0")
        #expect(GPUSampler.deviceUtilization(["GPU Activity(%)": 12]) == 0.12)
        #expect(GPUSampler.deviceUtilization(["Device Utilization %": 140]) == 1)
        // A virtual machine's paravirtual GPU publishes memory figures and nothing about load.
        let paravirtual: [String: Any] = ["Alloc system memory": 412_827_648, "In use system memory": 309_098_624, "recoveryCount": 0]
        #expect(GPUSampler.deviceUtilization(paravirtual) == nil)
        #expect(GPUSampler.deviceUtilization([:]) == nil)
        #expect(GPUSampler.fraction("Tiler Utilization %", in: paravirtual) == nil)
    }

    @Test func guessesInterfaceKinds() {
        #expect(NetworkSampler.guessKind("lo0", isLoopback: true) == .loopback)
        #expect(NetworkSampler.guessKind("utun3", isLoopback: false) == .vpn)
        #expect(NetworkSampler.guessKind("bridge100", isLoopback: false) == .bridge)
        #expect(NetworkSampler.guessKind("anpi0", isLoopback: false) == .other)
    }

    @Test func describesSockets() {
        let listener = SocketInfo(proto: .tcp, localAddress: "127.0.0.1", localPort: 3000,
                                  remoteAddress: nil, remotePort: nil, state: "LISTEN")
        #expect(ProcessInspector.describe(listener) == "TCP 127.0.0.1:3000 (LISTEN)")
        #expect(listener.isListening)

        let connection = SocketInfo(proto: .tcp, localAddress: "::1", localPort: 52100,
                                    remoteAddress: "::1", remotePort: 443, state: "ESTABLISHED")
        #expect(ProcessInspector.describe(connection) == "TCP [::1]:52100 → [::1]:443 (ESTABLISHED)")
        #expect(!connection.isListening)
    }

    @Test func bundlePathFromExecutable() {
        func sample(path: String?) -> ProcessSample {
            ProcessSample(pid: 1, parentPID: 0, responsiblePID: 1, uid: 0, userName: "root", name: "x",
                          executablePath: path, state: .running, nice: 0, startTime: nil, isTranslated: false,
                          isRestricted: false, cpuPercent: 0, cpuTime: 0, memory: 0, residentMemory: 0,
                          threadCount: 0, diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0)
        }
        #expect(sample(path: "/Applications/Safari.app/Contents/MacOS/Safari").bundlePath == "/Applications/Safari.app")
        #expect(sample(path: "/usr/bin/top").bundlePath == nil)
        #expect(sample(path: "/System/Library/Foo.framework/Contents/MacOS/Foo").bundlePath == nil)
    }

    @Test func readsTheDeviceAVolumeIsMountedFrom() {
        #expect(VolumeReader.bsdName(mountSource: "/dev/disk3s1s1") == "disk3s1s1")
        #expect(VolumeReader.bsdName(mountSource: "/dev/disk6s1") == "disk6s1")
        #expect(VolumeReader.bsdName(mountSource: "map auto_home") == nil)
        #expect(VolumeReader.bsdName(mountSource: "//guest@nas/share") == nil)
        #expect(VolumeReader.bsdName(mountSource: "devfs") == nil)
    }
}
