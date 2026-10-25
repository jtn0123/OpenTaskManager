import Foundation
@testable import OTMKit
import Testing

private let gib: UInt64 = 1 << 30

struct DiskScanRuleTests {
    @Test func hardLinksCountOncePerDeviceAndInode() {
        var ledger = HardLinkLedger()
        let counted = [
            ledger.count(device: 1, inode: 42, allocated: 4_096),
            ledger.count(device: 1, inode: 42, allocated: 4_096),
            ledger.count(device: 1, inode: 42, allocated: 4_096),
            // The same inode number on another file system is another file.
            ledger.count(device: 2, inode: 42, allocated: 8_192),
        ]
        #expect(counted == [true, false, false, true])
        #expect(ledger.duplicates == 2)
        #expect(ledger.duplicateSize == 8_192)
    }

    @Test func mountBoundaryKeepsToTheScannedVolumes() {
        var boundary = MountBoundary<String>(root: "/", allowed: ["system", "data"],
                                             mountPoints: ["/", "/System/Volumes/Data", "/System/Volumes/VM", "/Volumes/Backup", "/dev"])
        // The root itself is never a mount point to skip.
        #expect(boundary.mountPoints == ["/System/Volumes/Data", "/System/Volumes/VM", "/Volumes/Backup", "/dev"])
        #expect(boundary.deepestMount == 3)
        let entered = [
            // The Data volume reports the same volume as / but is a mount of its own.
            boundary.enters(depth: 3, volume: "system", path: { "/System/Volumes/Data" }),
            // Reached through a firmlink, the same volume is entered.
            boundary.enters(depth: 1, volume: "data", path: { "/Users" }),
            // Another volume, whatever its path.
            boundary.enters(depth: 2, volume: "backup", path: { "/Volumes/Backup" }),
            // A volume that couldn't be read is entered unless it's a mount point.
            boundary.enters(depth: 1, volume: nil, path: { "/dev" }),
            boundary.enters(depth: 1, volume: nil, path: { "/private" }),
            // Deeper than any mount point, the path isn't even looked at.
            boundary.enters(depth: 4, volume: "system", path: {
                Issue.record("looked up a path below every mount point")
                return ""
            }),
        ]
        #expect(entered == [false, true, false, false, true, true])
        #expect(boundary.skipped == ["/System/Volumes/Data", "/Volumes/Backup", "/dev"])
        #expect(boundary.skippedCount == 3)
    }

    @Test func mountBoundaryLooksOnlyInsideTheRoot() {
        let boundary = MountBoundary<Int>(root: "/Users/me", allowed: [1],
                                          mountPoints: ["/Users/me", "/Users/me/mnt/disk", "/Users/meToo", "/Volumes/X", "/"])
        #expect(boundary.mountPoints == ["/Users/me/mnt/disk"])
        #expect(boundary.deepestMount == 4)
        #expect(MountBoundary<Int>.depth(of: "/") == 0)
        #expect(MountBoundary<Int>.depth(of: "/System/Volumes/Data") == 3)
    }

    @Test func mountBoundaryListsTheFirstFewAndCountsTheRest() {
        var boundary = MountBoundary<Int>(root: "/", allowed: [1], mountPoints: [])
        for index in 0..<25 {
            let entered = boundary.enters(depth: 2, volume: 100 + index, path: { "/Volumes/Disk \(index)" })
            #expect(!entered)
        }
        #expect(boundary.skipped.count == MountBoundary<Int>.listLimit)
        #expect(boundary.skipped.first == "/Volumes/Disk 0")
        #expect(boundary.skippedCount == 25)
    }
}

struct DiskScanBoundaryTests {
    @Test func countsHardLinksOnceAndNotesTheSpaceNotCountedAgain() throws {
        let fixture = try Fixture()
        let original = try fixture.file("a/original.bin", size: 200_000)
        try fixture.folder("b")
        try FileManager.default.linkItem(at: original, to: fixture.url("b/second-name.bin"))
        try FileManager.default.linkItem(at: original, to: fixture.url("b/third-name.bin"))
        let usage = try #require(DiskUsageScanner.scan(DiskScanRequest(root: fixture.root)))
        let allocated = try fixture.allocated("a/original.bin")

        #expect(usage.root.allocatedSize == allocated)
        #expect(usage.hardLinkDuplicates == 2)
        #expect(usage.hardLinkDuplicateSize == 2 * allocated)
        #expect(usage.fileCount == 3)
    }

    @Test func notesTheVolumesUsedSpaceAsItStarts() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", size: 10)
        let usage = try #require(DiskUsageScanner.scan(DiskScanRequest(root: fixture.root)))
        let used = try #require(usage.volumeUsedAtStart)
        #expect(used > 0)
        #expect(usage.skippedVolumes.isEmpty && usage.skippedVolumeCount == 0)
    }

    /// /System/Volumes holds the startup disk's other volumes, each mounted
    /// there. The Data volume reports the same volume as the system's, so
    /// only its mount point keeps the scan out of it.
    @Test func neverCrossesIntoTheVolumesMountedInside() throws {
        #expect(MountTable.mountPoints().contains("/System/Volumes/Data"))
        var checks = 0
        // Entering the Data volume would take thousands of files: give up then.
        let usage = try #require(DiskUsageScanner.scan(DiskScanRequest(root: URL(fileURLWithPath: "/System/Volumes")), isCancelled: {
            checks += 1
            return checks > 4
        }))
        #expect(usage.skippedVolumes.contains("/System/Volumes/Data"))
        #expect(usage.skippedVolumeCount >= usage.skippedVolumes.count)
        #expect(usage.root.allocatedSize < 50 * 1_048_576)
    }

    @Test func readsTheVolumeAFixtureIsOn() throws {
        let fixture = try Fixture()
        try fixture.file("a/b.bin", size: 100_000)
        let request = DiskScanRequest(root: fixture.root)
        let usage = try #require(DiskUsageScanner.scan(request))
        let reconciliation = try #require(DiskReconciliationReader.read(usage, request: request, home: "/nonexistent-home"))

        #expect(reconciliation.scope == .folder)
        #expect(reconciliation.scan.allocated == usage.root.allocatedSize)
        #expect(reconciliation.space.capacity > 0 && reconciliation.space.used > 0)
        #expect(reconciliation.remainder == nil)
        #expect(reconciliation.contributors.isEmpty)
        let mounted = try #require(MountTable.volume(at: fixture.root.path))
        #expect(reconciliation.volume == mounted)
        if mounted.isAPFS, let container = reconciliation.container {
            #expect(!reconciliation.scannedVolumes.isEmpty)
            #expect(container.volumes.contains { $0.holds(device: mounted.device ?? "") })
        }
        // The fixture standing in for home.
        let asHome = try #require(DiskReconciliationReader.read(usage, request: request, home: fixture.root.path))
        #expect(asHome.scope == .home)
        #expect(asHome.remainder != nil)
    }
}

struct APFSListTests {
    static let list = """
    Unrelated warning printed first
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Containers</key>
        <array>
            <dict>
                <key>CapacityCeiling</key><integer>994662584320</integer>
                <key>CapacityFree</key><integer>385526235136</integer>
                <key>ContainerReference</key><string>disk3</string>
                <key>Volumes</key>
                <array>
                    <dict>
                        <key>CapacityInUse</key><integer>12000000000</integer>
                        <key>DeviceIdentifier</key><string>disk3s1</string>
                        <key>Name</key><string>Macintosh HD</string>
                        <key>Roles</key><array><string>System</string></array>
                    </dict>
                    <dict>
                        <key>CapacityInUse</key><integer>580000000000</integer>
                        <key>DeviceIdentifier</key><string>disk3s5</string>
                        <key>Name</key><string>Data</string>
                        <key>Roles</key><array><string>Data</string></array>
                    </dict>
                    <dict>
                        <key>CapacityInUse</key><integer>7000000000</integer>
                        <key>DeviceIdentifier</key><string>disk3s2</string>
                        <key>Name</key><string>Preboot</string>
                        <key>Roles</key><array><string>Preboot</string></array>
                    </dict>
                    <dict>
                        <key>CapacityInUse</key><integer>2147483648</integer>
                        <key>DeviceIdentifier</key><string>disk3s6</string>
                        <key>Name</key><string>VM</string>
                        <key>Roles</key><array><string>VM</string></array>
                    </dict>
                </array>
            </dict>
            <dict>
                <key>CapacityCeiling</key><integer>524288000</integer>
                <key>CapacityFree</key><integer>500000000</integer>
                <key>ContainerReference</key><string>disk1</string>
                <key>Volumes</key>
                <array>
                    <dict>
                        <key>CapacityInUse</key><integer>6000000</integer>
                        <key>DeviceIdentifier</key><string>disk1s1</string>
                        <key>Name</key><string>iSCPreboot</string>
                        <key>Roles</key><array><string>Preboot</string></array>
                    </dict>
                </array>
            </dict>
        </array>
    </dict>
    </plist>
    """

    @Test func parsesContainersAndTheirVolumes() throws {
        let containers = try #require(APFSContainer.parseList(Self.list))
        #expect(containers.map(\.reference) == ["disk3", "disk1"])
        let main = containers[0]
        #expect(main.capacity == 994_662_584_320)
        #expect(main.used == 994_662_584_320 - 385_526_235_136)
        #expect(main.volumes.map(\.device) == ["disk3s1", "disk3s5", "disk3s2", "disk3s6"])
        #expect(main.volumes[0].title == "Macintosh HD (System)")
        #expect(main.volumes[2].title == "Preboot")
        #expect(main.volumes[3].used == 2_147_483_648)
        // The system volume runs from a snapshot of disk3s1.
        #expect(APFSContainer.holding(device: "disk3s1s1", in: containers)?.reference == "disk3")
        #expect(main.volume(mountedFrom: "disk3s5")?.name == "Data")
        #expect(APFSContainer.holding(device: "disk1s1", in: containers)?.reference == "disk1")
        #expect(APFSContainer.holding(device: "disk7s1", in: containers) == nil)
        #expect(APFSContainer.parseList("Unable to run") == nil)
        #expect(APFSContainer.parseList("<plist version=\"1.0\"><dict><key>Other</key><true/></dict></plist>") == nil)
    }

    @Test func aVolumeHoldsItsOwnSnapshotsOnly() {
        let volume = APFSVolume(device: "disk3s1", name: "Macintosh HD", used: 0)
        #expect(volume.holds(device: "disk3s1"))
        #expect(volume.holds(device: "disk3s1s1"))
        #expect(volume.holds(device: "disk3s1s12"))
        #expect(!volume.holds(device: "disk3s10"))
        #expect(!volume.holds(device: "disk3s1s"))
        #expect(!volume.holds(device: "disk3s1sx"))
        #expect(!APFSVolume(device: "disk3s10", name: "Other", used: 0).holds(device: "disk3s1"))
    }

    static let snapshots = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>Snapshots</key>
        <array>
            <dict>
                <key>LimitingContainerShrink</key><false/>
                <key>Purgeable</key><true/>
                <key>SnapshotName</key><string>com.apple.TimeMachine.2026-10-06-120000.local</string>
                <key>SnapshotXID</key><integer>812345</integer>
            </dict>
            <dict>
                <key>SnapshotName</key><string>com.apple.os.update-ABC</string>
            </dict>
        </array>
    </dict>
    </plist>
    """

    @Test func readsSnapshotLists() throws {
        let read = SnapshotListing.reading(status: 0, output: Self.snapshots, volume: "/System/Volumes/Data")
        let snapshots = try #require(read.snapshots)
        #expect(snapshots.map(\.name) == ["com.apple.TimeMachine.2026-10-06-120000.local", "com.apple.os.update-ABC"])
        #expect(snapshots.map(\.isPurgeable) == [true, nil])
        #expect(snapshots.allSatisfy { $0.volume == "/System/Volumes/Data" })
        #expect(read.state == "listed")

        let empty = SnapshotListing.reading(status: 0, output: "<plist version=\"1.0\"><dict><key>Snapshots</key><array/></dict></plist>",
                                            volume: "/")
        #expect(empty == .listed([]))
        #expect(SnapshotListing.reading(status: 1, output: "Could not find disk for /Volumes/USB\n", volume: "/Volumes/USB") == .unreadable)
        #expect(SnapshotListing.reading(status: 1, output: "Error: This operation must be run as root", volume: "/") == .needsAdmin)
        #expect(SnapshotListing.reading(status: 1, output: "Operation not permitted", volume: "/") == .needsAdmin)
        // Killed at the timeout, or printed something else.
        #expect(SnapshotListing.reading(status: nil, output: "", volume: "/") == .unreadable)
        #expect(SnapshotListing.reading(status: 0, output: "garbage", volume: "/") == .unreadable)
    }

    @Test func combinesSeveralVolumesLists() {
        let first = APFSSnapshot(name: "a", volume: "/")
        let second = APFSSnapshot(name: "b", volume: "/System/Volumes/Data")
        #expect(SnapshotListing.combining([.listed([first]), .listed([second])]) == .listed([first, second]))
        #expect(SnapshotListing.combining([.listed([first]), .needsAdmin, .unreadable]) == .needsAdmin)
        #expect(SnapshotListing.combining([.listed([first]), .unreadable]) == .unreadable)
        #expect(SnapshotListing.combining([]) == .readOnly)
    }
}

struct DiskReconciliationTests {
    private let container = APFSContainer(reference: "disk3", capacity: 1_000 * gib, free: 300 * gib, volumes: [
        APFSVolume(device: "disk3s1", name: "Macintosh HD", roles: ["System"], used: 10 * gib),
        APFSVolume(device: "disk3s5", name: "Data", roles: ["Data"], used: 600 * gib),
        APFSVolume(device: "disk3s2", name: "Preboot", roles: ["Preboot"], used: 20 * gib),
        APFSVolume(device: "disk3s6", name: "VM", roles: ["VM"], used: 30 * gib),
    ])
    private let startup = MountedVolume(mountPoint: "/", device: "disk3s1s1", fileSystem: "apfs", isReadOnly: true)

    private func reconciliation(scope: ReconciliationScope = .wholeVolume, allocated: UInt64, alsoEnters: [String] = ["/System/Volumes/Data"],
                                snapshots: SnapshotListing = .listed([]), usedAtStart: UInt64? = nil,
                                container: APFSContainer? = nil) -> DiskReconciliation {
        let container = container ?? self.container
        return DiskReconciliation(scope: scope, volumeName: "Macintosh HD", volume: startup,
                                  space: VolumeSpace(capacity: 1_000 * gib, available: 300 * gib, availableForImportantUse: 340 * gib,
                                                     availableForOpportunisticUse: 280 * gib),
                                  container: container,
                                  scannedVolumes: DiskReconciliation.scannedVolumes(mountedFrom: ["disk3s1s1", "disk3s5"], in: container),
                                  snapshots: snapshots,
                                  scan: ScanTally(rootPath: scope == .folder ? "/Users/me/Projects" : "/", alsoEnters: alsoEnters,
                                                  allocated: allocated, logical: allocated, unreadableFolders: 3,
                                                  unreadablePaths: ["/private/var/db/x"], usedAtStart: usedAtStart))
    }

    @Test func classifiesTheScope() {
        #expect(ReconciliationScope.of(rootPath: "/", mountPoint: "/", homePath: "/Users/me") == .wholeVolume)
        #expect(ReconciliationScope.of(rootPath: "/Volumes/Backup", mountPoint: "/Volumes/Backup", homePath: "/Users/me") == .wholeVolume)
        #expect(ReconciliationScope.of(rootPath: "/Users/me", mountPoint: "/System/Volumes/Data", homePath: "/Users/me") == .home)
        #expect(ReconciliationScope.of(rootPath: "/Users/me/Projects", mountPoint: "/System/Volumes/Data", homePath: "/Users/me") == .folder)
    }

    @Test func volumeSpaceFigures() {
        let space = VolumeSpace(capacity: 1_000, available: 300, availableForImportantUse: 340, availableForOpportunisticUse: 280)
        #expect(space.used == 700)
        #expect(space.purgeable == 40)
        #expect(VolumeSpace(capacity: 1_000, available: 300).purgeable == nil)
        #expect(VolumeSpace(capacity: 1_000, available: 300, availableForImportantUse: 200).purgeable == 0)
        #expect(VolumeSpace(capacity: 100, available: 300).used == 0)
    }

    @Test func wholeVolumeRemainderLessTheOtherVolumes() throws {
        let whole = reconciliation(allocated: 550 * gib, usedAtStart: 690 * gib)
        #expect(whole.scannedVolumes == ["disk3s1", "disk3s5"])
        #expect(whole.otherVolumes.map(\.name) == ["VM", "Preboot"])
        #expect(whole.otherVolumesUsed == 50 * gib)
        #expect(whole.remainder == Int64(150 * gib))
        #expect(whole.rest == Int64(100 * gib))
        #expect(whole.changeDuringScan == Int64(10 * gib))
        #expect(whole.shareOfUsed != nil)
        #expect(whole.contributors.map(\.kind) == [.otherVolumes, .snapshots, .unreadableFolders, .unlinkedFolders, .metadata,
                                                   .changedDuringScan, .clones])
        let others = try #require(whole.contributors.first)
        #expect(others.bytes == Int64(50 * gib))
        #expect(others.count == 2)
        #expect(others.detail.hasPrefix("VM 30.0 GB, Preboot 20.0 GB."))
        #expect(whole.contributors.first { $0.kind == .unreadableFolders }?.figure == "3")
        #expect(whole.contributors.first { $0.kind == .changedDuringScan }?.figure == "+10.0 GB")
        #expect(whole.summary == "Macintosh HD: 700 GB used; this scan 550 GB; 150 GB not in it")
    }

    @Test func aScanLargerThanTheVolumesUseHasANegativeRemainder() {
        let whole = reconciliation(allocated: 800 * gib)
        #expect(whole.remainder == -Int64(100 * gib))
        #expect(whole.rest == -Int64(150 * gib))
        #expect(whole.summary.hasSuffix("100 GB more than the volume uses"))
        #expect(whole.changeDuringScan == nil)
        #expect(!whole.contributors.contains { $0.kind == .changedDuringScan })
    }

    @Test func aFolderGetsItsShareInstead() {
        let folder = reconciliation(scope: .folder, allocated: 350 * gib, alsoEnters: [])
        #expect(folder.remainder == nil)
        #expect(folder.rest == nil)
        #expect(folder.contributors.isEmpty)
        #expect(folder.shareOfUsed == 0.5)
        #expect(folder.shareOfCapacity == 0.35)
        #expect(folder.summary == "350 GB, 50% of the 700 GB used on Macintosh HD")
        let small = reconciliation(scope: .folder, allocated: 7 * gib, alsoEnters: [])
        #expect(small.summary == "7.00 GB, 1.0% of the 700 GB used on Macintosh HD")
        #expect(DiskReconciliation.shareWords(0.0004) == "under 0.1%")
        #expect(DiskReconciliation.shareWords(0.024) == "2.4%")
        #expect(DiskReconciliation.shareWords(0.163) == "16%")
    }

    @Test func homeNamesWhatsOutsideIt() {
        let home = reconciliation(scope: .home, allocated: 400 * gib, alsoEnters: [])
        #expect(home.remainder == Int64(300 * gib))
        #expect(home.contributors.contains { $0.kind == .outsideHome })
        #expect(!home.contributors.contains { $0.kind == .unlinkedFolders })
    }

    @Test func snapshotsAreNamedButNeverGivenTheRemainder() {
        let unreadable = reconciliation(allocated: 550 * gib, snapshots: .needsAdmin)
        let snapshot = unreadable.contributors.first { $0.kind == .snapshots }
        #expect(snapshot?.figure == "not readable without admin rights")
        #expect(snapshot?.bytes == nil)
        let listed = reconciliation(allocated: 550 * gib, snapshots: .listed([APFSSnapshot(name: "a", volume: "/"),
                                                                              APFSSnapshot(name: "b", volume: "/")]))
        #expect(listed.contributors.first { $0.kind == .snapshots }?.figure == "2")
        #expect(listed.contributors.first { $0.kind == .snapshots }?.bytes == nil)
        #expect(reconciliation(allocated: 550 * gib).contributors.first { $0.kind == .snapshots }?.figure == "none")
        #expect(!reconciliation(allocated: 550 * gib, snapshots: .notAPFS).contributors.contains { $0.kind == .snapshots })
        #expect(reconciliation(allocated: 550 * gib, snapshots: .unreadable).contributors.first { $0.kind == .snapshots }?.figure
            == "couldn't be read")
    }

    @Test func neverCallsTheRemainderSpaceToFree() {
        let cases = [
            reconciliation(allocated: 550 * gib, snapshots: .needsAdmin, usedAtStart: 600 * gib),
            reconciliation(scope: .home, allocated: 400 * gib, snapshots: .listed([APFSSnapshot(name: "a", volume: "/")])),
            reconciliation(allocated: 900 * gib, snapshots: .unreadable),
        ]
        for reconciliation in cases {
            let text = ([reconciliation.summary] + reconciliation.contributors.flatMap { [$0.title, $0.detail, $0.figure ?? ""] })
                .joined(separator: " ").lowercased()
            for word in ["deletable", "reclaimable", "free up", "can be freed", "can be deleted"] {
                #expect(!text.contains(word), "\(word)")
            }
        }
    }

    @Test func withoutAContainerThereAreNoOtherVolumes() {
        let plain = DiskReconciliation(scope: .wholeVolume, volumeName: "USB", volume: MountedVolume(mountPoint: "/Volumes/USB", device: "disk5s1",
                                                                                                     fileSystem: "msdos", isReadOnly: false),
                                       space: VolumeSpace(capacity: 64 * gib, available: 14 * gib), snapshots: .notAPFS,
                                       scan: ScanTally(rootPath: "/Volumes/USB", allocated: 49 * gib, logical: 49 * gib))
        #expect(plain.otherVolumes.isEmpty)
        #expect(plain.remainder == Int64(gib))
        #expect(plain.rest == Int64(gib))
        #expect(plain.contributors.map(\.kind) == [.unreadableFolders, .metadata])
        #expect(DiskReconciliation.scannedVolumes(mountedFrom: ["disk5s1"], in: nil).isEmpty)
    }
}
