import Foundation
@testable import OTMKit
import Testing

struct DiskActivityTests {
    private func disk(_ id: String, read: Double, write: Double, image: Bool = false) -> DiskSample {
        DiskSample(bsdName: id, model: image ? "Disk Image" : "SSD", isInternal: true, isSolidState: true, size: 100,
                   name: id, imagePath: image ? "/tmp/test.dmg" : nil, readBytesPerSecond: read, writeBytesPerSecond: write,
                   readOperationsPerSecond: 0, writeOperationsPerSecond: 0, totalRead: 0, totalWritten: 0, activeFraction: 0)
    }

    @Test func selectsCurrentPhysicalDevicesAndUsesRatesNotTotals() {
        let disks = [disk("disk10", read: 0, write: 1), disk("disk2", read: 10, write: 0), disk("disk0", read: 1, write: 1, image: true)]
        let all = DiskActivityLight.readings(disks, selection: .all, paused: false)
        #expect(all.map(\.id) == ["disk2", "disk10"])
        #expect(all.map(\.reading) == [true, false])
        #expect(all.map(\.writing) == [false, true])
        let selected = DiskActivityLight.readings(disks, selection: .init(rawValue: "disk10,disk99"), paused: false)
        #expect(selected.map(\.id) == ["disk10"])
        #expect(DiskActivityLight.readings(disks, selection: .init(rawValue: ""), paused: false).isEmpty)
    }

    @Test func pauseAndInvalidRatesNeverLightUp() {
        let sample = [disk("disk0", read: 10, write: 20), disk("disk1", read: .nan, write: -.infinity)]
        let paused = DiskActivityLight.readings(sample, selection: .all, paused: true)
        #expect(paused.allSatisfy { !$0.reading && !$0.writing })
        let invalid = DiskActivityLight.readings([sample[1]], selection: .all, paused: false)
        #expect(invalid.allSatisfy { !$0.reading && !$0.writing })
    }

    @Test func selectionCanBeEmptyAndAllFollowsNewlyConnectedDisks() {
        var selection = DiskLightSelection.all
        selection.toggle("disk0")
        #expect(!selection.isAll && selection.contains("disk0") && !selection.contains("disk1"))
        selection.toggle("disk0")
        #expect(selection.rawValue.isEmpty)
        #expect(DiskLightSelection.all.contains("disk999"))
    }

    @Test func fullPercentageScaleHasAnExactHundredPercentTop() {
        #expect(CPUGraphScale.auto.fixedMaximum == nil)
        #expect(CPUGraphScale.full.fixedMaximum == 1)
    }
}
