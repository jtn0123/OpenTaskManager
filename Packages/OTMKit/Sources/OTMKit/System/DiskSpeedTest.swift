import Darwin
import Foundation
import os

/// The four measurements, in the order a test runs them.
public enum DiskSpeedPhase: String, Sendable, Codable, CaseIterable {
    case sequentialWrite, sequentialRead, randomWrite, randomRead

    public var title: String {
        switch self {
        case .sequentialWrite: "Sequential write"
        case .sequentialRead: "Sequential read"
        case .randomWrite: "Random 4K write"
        case .randomRead: "Random 4K read"
        }
    }

    public var isWrite: Bool { self == .sequentialWrite || self == .randomWrite }
    public var isSequential: Bool { self == .sequentialWrite || self == .sequentialRead }
}

/// How big and how long a test is. Block sizes are fixed so results compare;
/// one operation is in flight at a time (queue depth 1).
public struct DiskSpeedConfiguration: Sendable, Codable, Equatable {
    public static let defaultFileSize: UInt64 = 1 << 30
    /// The test file never takes more than this share of the free space.
    public static let freeSpaceShare = 0.10

    /// The test file's size, read and written whole by the sequential phases.
    public var fileSize: UInt64
    public var sequentialBlockSize: Int
    public var randomBlockSize: Int
    /// Each random phase stops after this long or this many operations, whichever comes first.
    public var randomSeconds: Double
    public var randomOperationLimit: Int
    public var queueDepth = 1
    /// Seeds the data pattern and the random offsets.
    public var seed: UInt64

    public init(fileSize: UInt64 = defaultFileSize, sequentialBlockSize: Int = 1 << 20, randomBlockSize: Int = 4096,
                randomSeconds: Double = 3, randomOperationLimit: Int = 500_000, seed: UInt64 = .random(in: 1 ... .max)) {
        self.fileSize = fileSize
        self.sequentialBlockSize = sequentialBlockSize
        self.randomBlockSize = randomBlockSize
        self.randomSeconds = randomSeconds
        self.randomOperationLimit = randomOperationLimit
        self.seed = seed
    }

    /// Random blocks tile the sequential ones, and each holds its stamp.
    var isValid: Bool {
        randomBlockSize >= 16 && sequentialBlockSize >= randomBlockSize && sequentialBlockSize % randomBlockSize == 0
            && randomSeconds > 0 && randomOperationLimit > 0
    }
}

/// One phase's figures.
public struct DiskSpeedMeasurement: Sendable, Codable, Equatable {
    public var bytes: UInt64
    public var operations: Int
    /// Time spent in the reads or writes themselves, plus flushing writes to
    /// the disk at the end. Making and checking the data isn't counted.
    public var seconds: Double

    public init(bytes: UInt64, operations: Int, seconds: Double) {
        self.bytes = bytes
        self.operations = operations
        self.seconds = seconds
    }

    public var bytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    public var operationsPerSecond: Double { seconds > 0 ? Double(operations) / seconds : 0 }
}

/// Which volume a test ran on, so results are kept and compared per volume.
public struct DiskSpeedVolume: Sendable, Codable, Hashable {
    public var name: String
    public var mountPoint: String
    /// "apfs", "hfs", "smbfs"…
    public var fileSystem: String
    /// BSD names of the volume ("disk3s5") and of the disk it's on ("disk0").
    public var device: String?
    public var physicalDisk: String?
    public var uuid: String?

    public init(name: String, mountPoint: String, fileSystem: String, device: String? = nil, physicalDisk: String? = nil, uuid: String? = nil) {
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.device = device
        self.physicalDisk = physicalDisk
        self.uuid = uuid
    }

    public var key: String { uuid ?? mountPoint }

    /// The volume holding `path`.
    public static func containing(_ path: String) -> DiskSpeedVolume? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        func text<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let mountPoint = text(stats.f_mntonname)
        let device = VolumeReader.bsdName(mountSource: text(stats.f_mntfromname))
        let values = try? URL(fileURLWithPath: mountPoint, isDirectory: true).resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
        return DiskSpeedVolume(
            name: values?.volumeName ?? FileManager.default.displayName(atPath: mountPoint),
            mountPoint: mountPoint,
            fileSystem: text(stats.f_fstypename),
            device: device,
            physicalDisk: device.flatMap(IORegistry.physicalDisk(forBSDName:)),
            uuid: values?.volumeUUIDString
        )
    }
}

/// A finished test.
public struct DiskSpeedResult: SpeedTestRecord, Equatable, Identifiable {
    public static let currentVersion = 1

    public var id: Date { date }
    public var version = Self.currentVersion
    public var date: Date
    public var volume: DiskSpeedVolume
    /// The folder the test file was made in.
    public var folder: String
    /// As run: `fileSize` is after the free-space limit.
    public var configuration: DiskSpeedConfiguration
    /// Free space before the test.
    public var freeBytes: UInt64
    /// Whether the volume took `F_NOCACHE`, so reads came from the disk and
    /// not from memory.
    public var bypassedCache: Bool
    /// Whether writes were flushed through the disk's own cache
    /// (`F_FULLFSYNC`), not just handed to it (`fsync`).
    public var fullFlush: Bool
    public var sequentialWrite: DiskSpeedMeasurement
    public var sequentialRead: DiskSpeedMeasurement
    public var randomWrite: DiskSpeedMeasurement
    public var randomRead: DiskSpeedMeasurement
    /// The Mac's state as the test started and ended; nil in results saved
    /// before it was recorded.
    public var context: BenchmarkContext?

    public var historyKey: String { volume.key }

    public func measurement(_ phase: DiskSpeedPhase) -> DiskSpeedMeasurement {
        switch phase {
        case .sequentialWrite: sequentialWrite
        case .sequentialRead: sequentialRead
        case .randomWrite: randomWrite
        case .randomRead: randomRead
        }
    }
}

/// How far a running test is.
public struct DiskSpeedProgress: Sendable, Equatable {
    public var phase: DiskSpeedPhase
    /// 0...1 through this phase.
    public var phaseFraction: Double
    /// The phase's speed so far.
    public var bytesPerSecond: Double
    /// The phases already done.
    public var finished: [DiskSpeedPhase: DiskSpeedMeasurement] = [:]

    public init(phase: DiskSpeedPhase, phaseFraction: Double, bytesPerSecond: Double, finished: [DiskSpeedPhase: DiskSpeedMeasurement] = [:]) {
        self.phase = phase
        self.phaseFraction = phaseFraction
        self.bytesPerSecond = bytesPerSecond
        self.finished = finished
    }

    /// 0...1 through the whole test.
    public var fraction: Double {
        let index = Double(DiskSpeedPhase.allCases.firstIndex(of: phase) ?? 0)
        return (index + min(max(phaseFraction, 0), 1)) / Double(DiskSpeedPhase.allCases.count)
    }
}

public enum DiskSpeedError: Error, Equatable, Sendable {
    case notAFolder(String)
    /// The test file couldn't be made there; `code` is the errno.
    case notWritable(String, code: Int32)
    /// A tenth of the free space isn't even one block.
    case notEnoughSpace(free: UInt64)
    case ioFailed(DiskSpeedPhase, code: Int32)
    /// What was read back isn't what was written.
    case verificationFailed(DiskSpeedPhase, offset: UInt64)
    case cancelled

    public var message: String {
        switch self {
        case let .notAFolder(path): "There's no folder at \(path)."
        case let .notWritable(path, code):
            "Couldn't make a test file in \(path): \(String(cString: strerror(code))). Choose a folder you can write to."
        case let .notEnoughSpace(free): "Not enough free space: the test uses at most a tenth of the \(Format.bytes(free)) free."
        case let .ioFailed(phase, code): "\(phase.title) failed: \(String(cString: strerror(code)))."
        case let .verificationFailed(phase, offset):
            "\(phase.title) read back different data at byte \(offset.formatted()). The disk or its connection may be faulty."
        case .cancelled: "The test was cancelled."
        }
    }
}

/// Stops a running test from another thread; the test notices between operations.
public final class DiskSpeedCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() {
        flag.withLock { $0 = true }
    }

    public var isCancelled: Bool { flag.withLock { $0 } }
}

/// Measures a volume through one temporary file: sequential write and read
/// in 1 MB blocks, then 4K writes and reads at random offsets, one at a time,
/// with POSIX I/O and `F_NOCACHE` so reads come from the disk, not memory.
/// Every read is checked against what was written. It's a file-level test,
/// so APFS's caching, copy-on-write and compression still play a part.
public enum DiskSpeedTest {
    /// Test files start with this; the rest of the name is a fresh UUID.
    public static let filePrefix = ".otm-speedtest-"

    /// A temporary folder on the home volume.
    public static var defaultFolder: String { FileManager.default.temporaryDirectory.path }

    /// Free space at `path`, for the size limit.
    public static func freeBytes(at path: String) -> UInt64? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    }

    /// The file size a test uses: what was asked for, held to a tenth of the
    /// free space, in whole sequential blocks. Zero when not one block fits.
    public static func plannedSize(requested: UInt64, freeBytes: UInt64, blockSize: Int) -> UInt64 {
        let block = UInt64(max(blockSize, 1))
        let limit = min(requested, UInt64(Double(freeBytes) * DiskSpeedConfiguration.freeSpaceShare))
        return limit / block * block
    }

    /// How a result was measured, and what that means for reading it.
    public static func methodNote(_ result: DiskSpeedResult) -> String {
        ([fileLevelNote(result)] + cautions(result)).joined(separator: " ")
    }

    /// What any result's figures are: true of every run, so it can sit in a methodology.
    public static func fileLevelNote(_ result: DiskSpeedResult) -> String {
        "File-level results from a \(Format.wholeBytes(result.configuration.fileSize)) file, one request at a time, "
            + "so APFS caching and compression play a part and they can differ from the drive's rated speed."
    }

    /// What this result's volume did that flatters its figures, if anything,
    /// to keep beside them.
    public static func cautions(_ result: DiskSpeedResult) -> [String] {
        var cautions: [String] = []
        if !result.bypassedCache { cautions.append("This volume ignored F_NOCACHE, so reads may have come from memory.") }
        if !result.fullFlush { cautions.append("Writes were flushed with fsync only, so the disk's own cache may hold some.") }
        return cautions
    }

    /// Runs a test in `folder`, blocking the calling thread. The file is
    /// gone when this returns or throws, whatever happened.
    public static func run(in folder: String, configuration: DiskSpeedConfiguration = DiskSpeedConfiguration(),
                           cancellation: DiskSpeedCancellation? = nil,
                           progress: @escaping (DiskSpeedProgress) -> Void = { _ in }) throws(DiskSpeedError) -> DiskSpeedResult {
        precondition(configuration.isValid, "block sizes must tile")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { throw .notAFolder(folder) }
        let free = freeBytes(at: folder) ?? 0
        var settings = configuration
        settings.fileSize = plannedSize(requested: configuration.fileSize, freeBytes: free, blockSize: configuration.sequentialBlockSize)
        guard settings.fileSize > 0 else { throw .notEnoughSpace(free: free) }
        let volume = DiskSpeedVolume.containing(folder) ?? DiskSpeedVolume(name: folder, mountPoint: folder, fileSystem: "")

        let file = try TestFile(in: folder)
        defer { file.close() }
        let bypassedCache = fcntl(file.descriptor, F_NOCACHE, 1) != -1
        let run = SpeedRun(descriptor: file.descriptor, settings: settings, cancellation: cancellation, report: progress)
        let sequentialWrite = try run.measure(.sequentialWrite)
        let sequentialRead = try run.measure(.sequentialRead)
        let randomWrite = try run.measure(.randomWrite)
        let randomRead = try run.measure(.randomRead)
        return DiskSpeedResult(
            date: Date(), volume: volume, folder: folder, configuration: settings, freeBytes: free, bypassedCache: bypassedCache,
            fullFlush: run.fullFlush, sequentialWrite: sequentialWrite, sequentialRead: sequentialRead,
            randomWrite: randomWrite, randomRead: randomRead
        )
    }

    /// `run` on its own thread, so the test's blocking I/O doesn't hold a
    /// Swift concurrency thread. Cancelling the calling task stops it.
    public static func measure(in folder: String, configuration: DiskSpeedConfiguration = DiskSpeedConfiguration(),
                               progress: @escaping @Sendable (DiskSpeedProgress) -> Void) async throws(DiskSpeedError) -> DiskSpeedResult {
        let cancellation = DiskSpeedCancellation()
        let outcome: Result<DiskSpeedResult, DiskSpeedError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result { () throws(DiskSpeedError) -> DiskSpeedResult in
                        try run(in: folder, configuration: configuration, cancellation: cancellation, progress: progress)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try outcome.get()
    }
}

/// The test's file: uniquely named, made exclusively, and unlinked at once,
/// so it vanishes with its descriptor even if the test fails, is cancelled
/// or the process dies. Only if unlinking fails does closing delete it by name.
private struct TestFile {
    let descriptor: Int32
    let path: String
    let stillLinked: Bool

    init(in folder: String) throws(DiskSpeedError) {
        path = (folder as NSString).appendingPathComponent(DiskSpeedTest.filePrefix + UUID().uuidString + ".tmp")
        descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw .notWritable(folder, code: errno) }
        stillLinked = unlink(path) != 0
    }

    func close() {
        Darwin.close(descriptor)
        if stillLinked { unlink(path) }
    }
}

/// SplitMix64: a small, fast generator for the data and the offsets.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// One test's state, used from a single thread. Data is a random block
/// repeated through the file, with every 4K block stamped with its own index
/// and a generation (0 when written in sequence, 1 when rewritten at random),
/// so each block read back can be checked exactly.
private final class SpeedRun {
    private static let alignment = 16_384
    private static let reportInterval: UInt64 = 250_000_000

    private let descriptor: Int32
    private let settings: DiskSpeedConfiguration
    private let cancellation: DiskSpeedCancellation?
    private let report: (DiskSpeedProgress) -> Void
    private let pattern: UnsafeMutableRawBufferPointer
    private let buffer: UnsafeMutableRawBufferPointer
    private let expected: UnsafeMutableRawBufferPointer
    private var random: SplitMix64
    /// Which 4K blocks the random write phase rewrote, one bit each.
    private var rewritten: [UInt64]
    /// Progress goes out at each phase's start and at most four times a second.
    private var reportedPhase: DiskSpeedPhase?
    private var lastReport: UInt64 = 0
    private var finished: [DiskSpeedPhase: DiskSpeedMeasurement] = [:]
    private(set) var fullFlush = true

    init(descriptor: Int32, settings: DiskSpeedConfiguration, cancellation: DiskSpeedCancellation?,
         report: @escaping (DiskSpeedProgress) -> Void) {
        self.descriptor = descriptor
        self.settings = settings
        self.cancellation = cancellation
        self.report = report
        let size = settings.sequentialBlockSize
        pattern = .allocate(byteCount: size, alignment: Self.alignment)
        buffer = .allocate(byteCount: size, alignment: Self.alignment)
        expected = .allocate(byteCount: size, alignment: Self.alignment)
        random = SplitMix64(state: settings.seed)
        let slots = settings.fileSize / UInt64(settings.randomBlockSize)
        rewritten = Array(repeating: 0, count: Int((slots + 63) / 64))
        var fill = SplitMix64(state: ~settings.seed)
        for offset in stride(from: 0, to: size - 7, by: 8) {
            pattern.storeBytes(of: fill.next(), toByteOffset: offset, as: UInt64.self)
        }
    }

    deinit {
        pattern.deallocate()
        buffer.deallocate()
        expected.deallocate()
    }

    private var slotCount: UInt64 { settings.fileSize / UInt64(settings.randomBlockSize) }

    // MARK: Phases

    /// Runs one phase and keeps its figures for the progress reports.
    func measure(_ phase: DiskSpeedPhase) throws(DiskSpeedError) -> DiskSpeedMeasurement {
        let measurement = switch phase {
        case .sequentialWrite: try sequentialWrite()
        case .sequentialRead: try sequentialRead()
        case .randomWrite: try randomWrite()
        case .randomRead: try randomRead()
        }
        finished[phase] = measurement
        return measurement
    }

    private func sequentialWrite() throws(DiskSpeedError) -> DiskSpeedMeasurement {
        let block = settings.sequentialBlockSize
        let blocks = Int(settings.fileSize / UInt64(block))
        var nanoseconds: UInt64 = 0
        for index in 0..<blocks {
            try checkCancelled()
            let offset = UInt64(index * block)
            fill(buffer, length: block, at: offset, generation: 0)
            nanoseconds += try transfer(.sequentialWrite, buffer, length: block, at: offset)
            progress(.sequentialWrite, done: Double(index + 1) / Double(blocks), bytes: offset + UInt64(block), nanoseconds: nanoseconds)
        }
        nanoseconds += flush()
        return DiskSpeedMeasurement(bytes: settings.fileSize, operations: blocks, seconds: Double(nanoseconds) / 1e9)
    }

    private func sequentialRead() throws(DiskSpeedError) -> DiskSpeedMeasurement {
        let block = settings.sequentialBlockSize
        let blocks = Int(settings.fileSize / UInt64(block))
        var nanoseconds: UInt64 = 0
        for index in 0..<blocks {
            try checkCancelled()
            let offset = UInt64(index * block)
            nanoseconds += try transfer(.sequentialRead, buffer, length: block, at: offset)
            fill(expected, length: block, at: offset, generation: 0)
            guard memcmp(buffer.baseAddress, expected.baseAddress, block) == 0 else {
                throw .verificationFailed(.sequentialRead, offset: offset)
            }
            progress(.sequentialRead, done: Double(index + 1) / Double(blocks), bytes: offset + UInt64(block), nanoseconds: nanoseconds)
        }
        return DiskSpeedMeasurement(bytes: settings.fileSize, operations: blocks, seconds: Double(nanoseconds) / 1e9)
    }

    private func randomWrite() throws(DiskSpeedError) -> DiskSpeedMeasurement {
        var result = try randomPhase(.randomWrite) { (slot: UInt64, offset: UInt64) throws(DiskSpeedError) -> UInt64 in
            fill(buffer, length: settings.randomBlockSize, at: offset, generation: 1)
            let nanoseconds = try transfer(.randomWrite, buffer, length: settings.randomBlockSize, at: offset)
            rewritten[Int(slot / 64)] |= 1 << (slot % 64)
            return nanoseconds
        }
        result.seconds += Double(flush()) / 1e9
        return result
    }

    private func randomRead() throws(DiskSpeedError) -> DiskSpeedMeasurement {
        try randomPhase(.randomRead) { (slot: UInt64, offset: UInt64) throws(DiskSpeedError) -> UInt64 in
            let length = settings.randomBlockSize
            let nanoseconds = try transfer(.randomRead, buffer, length: length, at: offset)
            let generation: UInt64 = rewritten[Int(slot / 64)] & (1 << (slot % 64)) != 0 ? 1 : 0
            fill(expected, length: length, at: offset, generation: generation)
            guard memcmp(buffer.baseAddress, expected.baseAddress, length) == 0 else {
                throw .verificationFailed(.randomRead, offset: offset)
            }
            return nanoseconds
        }
    }

    /// Runs `operation` on random blocks until the phase's time or count is
    /// up. It returns the nanoseconds its I/O took.
    private func randomPhase(_ phase: DiskSpeedPhase,
                             _ operation: (UInt64, UInt64) throws(DiskSpeedError) -> UInt64) throws(DiskSpeedError) -> DiskSpeedMeasurement {
        let start = Self.now()
        let limit = UInt64(settings.randomSeconds * 1e9)
        let slots = slotCount
        var operations = 0
        var nanoseconds: UInt64 = 0
        while operations < settings.randomOperationLimit, Self.now() - start < limit {
            try checkCancelled()
            let slot = random.next() % slots
            nanoseconds += try operation(slot, slot * UInt64(settings.randomBlockSize))
            operations += 1
            let done = max(Double(Self.now() - start) / Double(limit), Double(operations) / Double(settings.randomOperationLimit))
            progress(phase, done: done, bytes: UInt64(operations * settings.randomBlockSize), nanoseconds: nanoseconds)
        }
        return DiskSpeedMeasurement(bytes: UInt64(operations * settings.randomBlockSize), operations: operations,
                                    seconds: Double(nanoseconds) / 1e9)
    }

    // MARK: I/O

    /// Reads or writes `length` bytes at `offset`, returning the nanoseconds it took.
    private func transfer(_ phase: DiskSpeedPhase, _ memory: UnsafeMutableRawBufferPointer, length: Int,
                          at offset: UInt64) throws(DiskSpeedError) -> UInt64 {
        guard let base = memory.baseAddress else { return 0 }
        var done = 0
        var elapsed: UInt64 = 0
        while done < length {
            let start = Self.now()
            let position = off_t(offset) + off_t(done)
            let count = phase.isWrite ? pwrite(descriptor, base + done, length - done, position)
                : pread(descriptor, base + done, length - done, position)
            let code = errno
            elapsed += Self.now() - start
            if count < 0, code == EINTR { continue }
            guard count > 0 else { throw .ioFailed(phase, code: count < 0 ? code : EIO) }
            done += count
        }
        return elapsed
    }

    /// Pushes written data through to the disk, returning the nanoseconds it took.
    private func flush() -> UInt64 {
        let start = Self.now()
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            fullFlush = false
            fsync(descriptor)
        }
        return Self.now() - start
    }

    /// The pattern's bytes for `length` bytes of the file at `offset`, each
    /// 4K block stamped with its index and `generation`.
    private func fill(_ memory: UnsafeMutableRawBufferPointer, length: Int, at offset: UInt64, generation: UInt64) {
        guard let destination = memory.baseAddress, let source = pattern.baseAddress else { return }
        let start = Int(offset % UInt64(pattern.count))
        destination.copyMemory(from: source + start, byteCount: length)
        let unit = settings.randomBlockSize
        for position in stride(from: 0, to: length, by: unit) {
            let slot = (offset + UInt64(position)) / UInt64(unit)
            destination.storeBytes(of: slot ^ settings.seed, toByteOffset: position, as: UInt64.self)
            destination.storeBytes(of: generation ^ (settings.seed >> 1), toByteOffset: position + 8, as: UInt64.self)
        }
    }

    // MARK: Bookkeeping

    private func checkCancelled() throws(DiskSpeedError) {
        if cancellation?.isCancelled == true { throw .cancelled }
    }

    private func progress(_ phase: DiskSpeedPhase, done: Double, bytes: UInt64, nanoseconds: UInt64) {
        let now = Self.now()
        guard phase != reportedPhase || now - lastReport >= Self.reportInterval else { return }
        reportedPhase = phase
        lastReport = now
        let speed = nanoseconds > 0 ? Double(bytes) / (Double(nanoseconds) / 1e9) : 0
        report(DiskSpeedProgress(phase: phase, phaseFraction: min(done, 1), bytesPerSecond: speed, finished: finished))
    }

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

public extension Format {
    /// Decimal megabytes a second, the usual unit for disk speed: "2,950 MB/s",
    /// "48.2 MB/s", "0.85 MB/s".
    static func megabytesPerSecond(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let megabytes = bytesPerSecond / 1_000_000
        if megabytes >= 100 { return "\(Int(megabytes.rounded()).formatted()) MB/s" }
        return "\(fixed(megabytes, megabytes >= 10 ? 1 : 2)) MB/s"
    }

    /// A size in whole binary units where it is one: "1 GB", "512 MB",
    /// "4 KB"; otherwise as `bytes`.
    static func wholeBytes(_ value: UInt64) -> String {
        for (shift, unit) in [(40, "TB"), (30, "GB"), (20, "MB"), (10, "KB")] where value >= 1 << shift && value % (1 << shift) == 0 {
            return "\(value >> shift) \(unit)"
        }
        return bytes(value)
    }

    /// Operations a second: "12,480 IOPS", "8.5 IOPS".
    static func operationsPerSecond(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()).formatted()) IOPS" }
        return "\(fixed(value, 1)) IOPS"
    }
}
