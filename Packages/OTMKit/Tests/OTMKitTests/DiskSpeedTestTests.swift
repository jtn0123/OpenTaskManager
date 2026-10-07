import Foundation
@testable import OTMKit
import Testing

/// A test small enough to run in a moment: 256 KB in 64 KB blocks, and
/// random phases cut short.
private func tiny(seconds: Double = 0.05, operations: Int = 32) -> DiskSpeedConfiguration {
    DiskSpeedConfiguration(fileSize: 256 << 10, sequentialBlockSize: 64 << 10, randomBlockSize: 4096,
                           randomSeconds: seconds, randomOperationLimit: operations, seed: 42)
}

/// A fresh, empty folder of the test's own under the temporary folder.
private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("otm-diskspeed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func contents(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
}

struct DiskSpeedTestTests {
    @Test func holdsTheFileToATenthOfTheFreeSpace() {
        let gigabyte: UInt64 = 1 << 30
        let block = 1 << 20
        #expect(DiskSpeedTest.plannedSize(requested: gigabyte, freeBytes: 100 * gigabyte, blockSize: block) == gigabyte)
        #expect(DiskSpeedTest.plannedSize(requested: gigabyte, freeBytes: 5 * gigabyte, blockSize: block) == 512 << 20)
        // Rounded down to whole blocks.
        #expect(DiskSpeedTest.plannedSize(requested: gigabyte, freeBytes: 25 << 20, blockSize: block) == 2 << 20)
        #expect(DiskSpeedTest.plannedSize(requested: gigabyte, freeBytes: 5 << 20, blockSize: block) == 0)
        #expect(DiskSpeedTest.plannedSize(requested: 3 << 20, freeBytes: 100 * gigabyte, blockSize: block) == 3 << 20)
    }

    @Test func measuresChecksAndCleansUp() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var phases: [DiskSpeedPhase] = []
        var last: DiskSpeedProgress?
        let result = try DiskSpeedTest.run(in: folder.path, configuration: tiny()) { progress in
            if phases.last != progress.phase {
                phases.append(progress.phase)
                // Each phase starts with the figures of the ones before it.
                #expect(Set(progress.finished.keys) == Set(DiskSpeedPhase.allCases.prefix(phases.count - 1)))
            }
            #expect((0...1).contains(progress.fraction))
            last = progress
        }

        #expect(phases == DiskSpeedPhase.allCases)
        #expect(last?.finished[.randomWrite] == result.randomWrite)
        #expect(result.configuration.fileSize == 256 << 10)
        #expect(result.folder == folder.path)
        for phase in DiskSpeedPhase.allCases where phase.isSequential {
            let measurement = result.measurement(phase)
            #expect(measurement.bytes == 256 << 10 && measurement.operations == 4)
            #expect(measurement.seconds > 0 && measurement.bytesPerSecond > 0)
        }
        for phase in DiskSpeedPhase.allCases where !phase.isSequential {
            let measurement = result.measurement(phase)
            #expect((1...32).contains(measurement.operations))
            #expect(measurement.bytes == UInt64(measurement.operations * 4096))
            #expect(measurement.operationsPerSecond > 0)
        }
        #expect(!result.volume.mountPoint.isEmpty && !result.volume.fileSystem.isEmpty)
        #expect(result.historyKey == result.volume.key)
        #expect(result.freeBytes > 0)
        // The test file never outlives the test.
        #expect(try contents(folder).isEmpty)
    }

    @Test func cancellingStopsTheTestAndDeletesTheFile() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cancellation = DiskSpeedCancellation()
        #expect(throws: DiskSpeedError.cancelled) {
            try DiskSpeedTest.run(in: folder.path, configuration: tiny(), cancellation: cancellation) { progress in
                if progress.phase == .sequentialRead { cancellation.cancel() }
            }
        }
        #expect(try contents(folder).isEmpty)

        // Cancelled before it starts: nothing is written.
        #expect(throws: DiskSpeedError.cancelled) {
            try DiskSpeedTest.run(in: folder.path, configuration: tiny(), cancellation: cancellation)
        }
        #expect(try contents(folder).isEmpty)
    }

    @Test func cancellingTheTaskStopsALongRandomPhase() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let task = Task {
            try await DiskSpeedTest.measure(in: folder.path, configuration: tiny(seconds: 60, operations: .max)) { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: DiskSpeedError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try contents(folder).isEmpty)
    }

    @Test func refusesFoldersItCantUse() throws {
        let folder = try scratchFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let missing = folder.appendingPathComponent("missing").path
        #expect(throws: DiskSpeedError.notAFolder(missing)) {
            try DiskSpeedTest.run(in: missing, configuration: tiny())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(throws: DiskSpeedError.notWritable(folder.path, code: EACCES)) {
            try DiskSpeedTest.run(in: folder.path, configuration: tiny())
        }
    }

    @Test func describesTheVolume() throws {
        let volume = try #require(DiskSpeedVolume.containing(FileManager.default.temporaryDirectory.path))
        #expect(!volume.name.isEmpty)
        #expect(volume.key == volume.uuid ?? volume.mountPoint)
        #expect(DiskSpeedVolume.containing("/no/such/place") == nil)
    }

    @Test func progressCoversTheWholeTest() {
        #expect(DiskSpeedProgress(phase: .sequentialWrite, phaseFraction: 0, bytesPerSecond: 0).fraction == 0)
        #expect(DiskSpeedProgress(phase: .sequentialRead, phaseFraction: 0.5, bytesPerSecond: 0).fraction == 0.375)
        #expect(DiskSpeedProgress(phase: .randomRead, phaseFraction: 1, bytesPerSecond: 0).fraction == 1)
    }

    @Test func explainsEachError() {
        let errors: [DiskSpeedError] = [
            .notAFolder("/x"), .notWritable("/x", code: EACCES), .notEnoughSpace(free: 1 << 20),
            .ioFailed(.randomWrite, code: EIO), .verificationFailed(.sequentialRead, offset: 4096), .cancelled,
        ]
        for error in errors { #expect(error.message.hasSuffix(".")) }
        #expect(DiskSpeedError.notWritable("/x", code: EACCES).message.contains("Permission denied"))
    }

    @Test func formatsSpeedsAndSizes() throws {
        #expect(Format.megabytesPerSecond(2_950_400_000) == "2,950 MB/s")
        #expect(Format.megabytesPerSecond(48_240_000) == "48.2 MB/s")
        #expect(Format.megabytesPerSecond(850_000) == "0.85 MB/s")
        #expect(Format.megabytesPerSecond(.nan) == "—")
        #expect(Format.operationsPerSecond(12_480.4) == "12,480 IOPS")
        #expect(Format.operationsPerSecond(8.46) == "8.5 IOPS")
        #expect(Format.wholeBytes(1 << 30) == "1 GB")
        #expect(Format.wholeBytes(512 << 20) == "512 MB")
        #expect(Format.wholeBytes(4096) == "4 KB")
        #expect(Format.wholeBytes(1_500_000) == Format.bytes(UInt64(1_500_000)))

        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var result = try DiskSpeedTest.run(in: folder.path, configuration: tiny(operations: 4))
        result.bypassedCache = true
        result.fullFlush = true
        #expect(DiskSpeedTest.methodNote(result).hasPrefix("File-level results from a 256 KB file"))
        #expect(!DiskSpeedTest.methodNote(result).contains("F_NOCACHE"))
        result.bypassedCache = false
        result.fullFlush = false
        #expect(DiskSpeedTest.methodNote(result).contains("ignored F_NOCACHE"))
        #expect(DiskSpeedTest.methodNote(result).contains("fsync only"))
    }

    @Test func resultsRoundTripThroughJSON() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try DiskSpeedTest.run(in: folder.path, configuration: tiny(operations: 4))
        let decoded = try JSONDecoder().decode(DiskSpeedResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }
}
