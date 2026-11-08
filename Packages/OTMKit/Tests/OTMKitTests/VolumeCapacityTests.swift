@testable import OTMKit
import Testing

struct VolumeCapacityTests {
    private static let gigabyte: UInt64 = 1 << 30

    private func volume(total: UInt64, available: UInt64, free: UInt64?) -> VolumeInfo {
        VolumeInfo(name: "Macintosh HD", mountPoint: "/", fileSystem: "APFS", totalBytes: total * Self.gigabyte,
                   availableBytes: available * Self.gigabyte, freeBytes: free.map { $0 * Self.gigabyte },
                   isInternal: true, isRemovable: false, isRoot: true, physicalDisk: "disk0")
    }

    @Test func purgeableIsWhatImportantUseAddsToTheFreeSpace() {
        let capacity = VolumeCapacity(volume(total: 100, available: 40, free: 30))
        #expect(capacity.used == 60 * Self.gigabyte)
        #expect(capacity.purgeable == 10 * Self.gigabyte)
        #expect(capacity.free == 30 * Self.gigabyte)
        #expect(capacity.available == 40 * Self.gigabyte)
        #expect(capacity.share(of: capacity.used) + capacity.share(of: capacity.purgeable ?? 0)
            + capacity.share(of: capacity.free) == 1)
        #expect(capacity.used == volume(total: 100, available: 40, free: 30).usedBytes)
        #expect(capacity.summary == "60.0 GB used, 10.0 GB purgeable and 30.0 GB free, of 100 GB")
    }

    @Test func withoutAFreeFigureNothingIsCalledPurgeable() {
        let capacity = VolumeCapacity(volume(total: 100, available: 40, free: nil))
        #expect(capacity.purgeable == nil)
        #expect(capacity.free == 40 * Self.gigabyte)
        #expect(capacity.used == 60 * Self.gigabyte)
        #expect(capacity.summary == "60.0 GB used and 40.0 GB free, of 100 GB")
    }

    @Test func freeSpaceHeldBackFromImportantUseStillCountsAsFree() {
        let capacity = VolumeCapacity(volume(total: 100, available: 20, free: 25))
        #expect(capacity.purgeable == 0)
        #expect(capacity.free == 25 * Self.gigabyte)
        #expect(capacity.used == 75 * Self.gigabyte)
        #expect(capacity.summary == "75.0 GB used and 25.0 GB free, of 100 GB")
    }

    @Test func figuresPastTheCapacityAreHeldToIt() {
        let capacity = VolumeCapacity(volume(total: 100, available: 120, free: 110))
        #expect(capacity.free == 100 * Self.gigabyte)
        #expect(capacity.purgeable == 0)
        #expect(capacity.used == 0)
        #expect(VolumeCapacity(volume(total: 0, available: 0, free: 0)).share(of: 0) == 0)
    }
}
