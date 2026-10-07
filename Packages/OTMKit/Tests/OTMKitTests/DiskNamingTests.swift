@testable import OTMKit
import Testing

struct DiskNamingTests {
    private typealias Volume = DiskNaming.Volume

    /// The internal SSD as a Mac mounts it: the startup volume and its hidden system volumes.
    private let startupDisk = [
        Volume(name: "Macintosh HD", disk: "disk0", isRoot: true, isBrowsable: true),
        Volume(name: "Data", disk: "disk0", isRoot: false, isBrowsable: false),
        Volume(name: "Preboot", disk: "disk0", isRoot: false, isBrowsable: false),
        Volume(name: "VM", disk: "disk0", isRoot: false, isBrowsable: false),
    ]

    @Test func theStartupDiskTakesTheStartupVolumesName() {
        #expect(DiskNaming.name(of: "disk0", volumes: startupDisk, imagePath: nil) == "Macintosh HD")
    }

    @Test func aDriveTakesTheVolumesTheFinderShows() {
        let volumes = startupDisk + [
            Volume(name: "Backup", disk: "disk6", isRoot: false, isBrowsable: true),
            Volume(name: "Media", disk: "disk8", isRoot: false, isBrowsable: true),
            Volume(name: "Archive", disk: "disk8", isRoot: false, isBrowsable: true),
            Volume(name: "Photos", disk: "disk9", isRoot: false, isBrowsable: true),
            Volume(name: "Music", disk: "disk9", isRoot: false, isBrowsable: true),
            Volume(name: "Films", disk: "disk9", isRoot: false, isBrowsable: true),
        ]
        #expect(DiskNaming.name(of: "disk6", volumes: volumes, imagePath: nil) == "Backup")
        #expect(DiskNaming.name(of: "disk8", volumes: volumes, imagePath: nil) == "Archive, Media")
        #expect(DiskNaming.name(of: "disk9", volumes: volumes, imagePath: nil) == "Films and 2 more")
    }

    @Test func aDriveWithOnlyHiddenVolumesOrNoneKeepsItsDeviceName() {
        let volumes = [Volume(name: "Recovery", disk: "disk2", isRoot: false, isBrowsable: false)]
        #expect(DiskNaming.name(of: "disk2", volumes: volumes, imagePath: nil) == nil)
        #expect(DiskNaming.name(of: "disk5", volumes: volumes, imagePath: nil) == nil)
    }

    @Test func aDiskImageTakesItsVolumeThenItsFile() {
        let volumes = [
            Volume(name: "Firefox", disk: "disk4", isRoot: false, isBrowsable: true),
            Volume(name: "RevivalC13.UC_SIRI_Cryptex", disk: "disk6", isRoot: false, isBrowsable: false),
        ]
        #expect(DiskNaming.name(of: "disk4", volumes: volumes, imagePath: "/Users/me/Downloads/Firefox 131.0.dmg") == "Firefox")
        // A system asset's image mounts hidden: its file names it better than its volume.
        #expect(DiskNaming.name(of: "disk6", volumes: volumes, imagePath: "/System/Library/AssetsV2/x.asset/UC_SIRI_Cryptex.dmg")
            == "UC_SIRI_Cryptex")
        #expect(DiskNaming.name(of: "disk6", volumes: volumes, imagePath: "/") == "RevivalC13.UC_SIRI_Cryptex")
        #expect(DiskNaming.name(of: "disk7", volumes: volumes, imagePath: "/tmp/scratch.sparseimage") == "scratch")
    }

    @Test func imageNameDropsOnlyTheExtension() {
        #expect(DiskNaming.imageName("/tmp/Firefox 131.0.dmg") == "Firefox 131.0")
        #expect(DiskNaming.imageName("/tmp/README") == "README")
        #expect(DiskNaming.imageName("/") == nil)
        #expect(DiskNaming.imageName("") == nil)
    }

    @Test func liveDisksAreNamedWithoutCrashing() {
        let names = DiskNameReader.read(disks: ["disk0"])
        #expect(names.keys.contains("disk0"))
        #expect(DiskNameReader.mountCount() > 0)
    }
}
