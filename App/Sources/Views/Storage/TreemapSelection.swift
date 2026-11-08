import OTMKit
import SwiftUI

/// Canvas labels can disappear in narrow tiles; every drawn item still has a spoken name.
struct TreemapKeyboard: View {
    let layout: TreemapLayout
    let hover: StorageHover
    var select: (DiskItem) -> Void
    var open: (DiskItem) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Treemap")
            .accessibilityChildren {
                ForEach(layout.navigation, id: \.id) { tile in
                    if let item = Self.item(tile.id, in: layout) {
                        Button { select(item) } label: {
                            Text("\(StorageStyle.name(item)), \(Format.bytes(item.allocatedSize))")
                        }
                        .accessibilityAddTraits(hover.selected == item.id ? .isSelected : [])
                        .accessibilityAction(named: "Open Folder") {
                            if item.isFolder { open(item) }
                        }
                    }
                }
            }
    }

    static func item(_ id: Int, in layout: TreemapLayout) -> DiskItem? {
        for tile in layout.tiles {
            if tile.id == id { return tile.item }
            if let inner = tile.inner(id: id)?.item { return inner }
        }
        return nil
    }

    static func move(_ command: MoveCommandDirection, layout: TreemapLayout, hover: StorageHover, select: (DiskItem) -> Void) {
        let direction: TreemapNavigation.Direction
        switch command {
        case .left: direction = .left
        case .right: direction = .right
        case .up: direction = .up
        case .down: direction = .down
        @unknown default: return
        }
        guard let id = TreemapNavigation.next(from: hover.selected, direction: direction, tiles: layout.navigation),
              let item = item(id, in: layout) else { return }
        select(item)
    }
}

/// The pointer and selection alone read this strip, so naming a tiny tile doesn't redraw the map.
struct TreemapSelectionStrip: View {
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if let id = hover.inner ?? hover.item ?? hover.selected, usage.items.indices.contains(id) {
                    let item = usage.items[id]
                    let share = Double(item.allocatedSize) / Double(max(folder.allocatedSize, 1))
                    Text(StorageStyle.name(item)).font(.tableText.weight(.semibold))
                    Text(relativePath(of: item)).font(.explanation).foregroundStyle(.secondaryText)
                    Text("\(Format.bytes(item.allocatedSize)) · \(Format.percent(share, digits: 1)) of this folder")
                        .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                } else {
                    Text("Select or hover a tile to see its name and path.").font(.explanation).foregroundStyle(.secondaryText)
                    Text("Arrow keys select nearby tiles. Return or double-click opens a folder.")
                        .font(.explanation).foregroundStyle(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
        // Hovering a longer name must not resize the treemap under the pointer.
        .frame(height: 80)
        .accessibilityElement(children: .combine)
    }

    private func relativePath(of item: DiskItem) -> String {
        let path = usage.path(of: item.id)
        let trail = Format.trailNames(path, under: usage.rootPath).joined(separator: "/")
        let relative = trail.isEmpty ? "." : trail
        return item.kind == .smallerItems ? relative + "/" + StorageStyle.name(item) : relative
    }
}
