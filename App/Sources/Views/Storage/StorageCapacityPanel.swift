import OTMKit
import SwiftUI

/// The space on the startup disk and the other local volumes, over the
/// places to scan, so how full a disk is needs no scan. Read when the page
/// opens (`StorageStore.loadVolumes`), never per tick.
struct StorageCapacityPanel: View {
    let volumes: [VolumeInfo]

    var body: some View {
        Card(tint: Theme.disk, glow: 0.08) {
            ForEach(volumes) { volume in
                if volume.id != volumes.first?.id { Divider() }
                CapacityRow(volume: volume)
            }
        }
        // A card fills the height it's offered, and the start view offers the page's.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CapacityRow: View {
    let volume: VolumeInfo

    var body: some View {
        let capacity = VolumeCapacity(volume)
        let scope = StorageScope.volume(volume)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: scope.symbol).font(.title2).foregroundStyle(Theme.disk).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name).font(.headline)
                    Text([scope.subtitle, volume.fileSystem].compactMap(\.self).joined(separator: " · "))
                        .font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Format.bytes(capacity.available)) available").font(.title3.weight(.semibold))
                    Text("of \(Format.bytes(capacity.capacity))").font(.metadata).foregroundStyle(.secondaryText)
                }
                .monospacedDigit()
                .help("Free now, and space macOS clears by itself when it's needed")
            }
            ShareBar(segments: [(Theme.disk, capacity.share(of: capacity.used)),
                                (purgeableColor, capacity.share(of: capacity.purgeable ?? 0)),
                                (freeColor, capacity.share(of: capacity.free))])
                .frame(height: 10)
            HStack(spacing: 18) {
                CapacityKey(color: Theme.disk, title: "Used", bytes: capacity.used)
                if let purgeable = capacity.purgeable, purgeable > 0 {
                    CapacityKey(color: purgeableColor, title: "Purgeable", bytes: purgeable)
                        .help("Caches and other files macOS removes by itself when space runs short. "
                            + "It counts as available, as it does in Finder.")
                }
                CapacityKey(color: freeColor, title: "Free", bytes: capacity.free)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name): \(capacity.summary)")
    }

    // Read in the body, so a palette change redraws the row.
    private var purgeableColor: Color { Theme.disk.opacity(0.45) }
    private var freeColor: Color { Color.secondary.opacity(0.25) }
}

/// A bar segment's swatch, its name and its figure.
private struct CapacityKey: View {
    let color: Color
    let title: String
    let bytes: UInt64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .frame(width: 10, height: 10)
            Text(title).foregroundStyle(.secondaryText)
            Text(Format.bytes(bytes)).monospacedDigit()
        }
        .font(.metadata)
    }
}
