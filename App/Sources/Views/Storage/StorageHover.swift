import OTMKit
import SwiftUI

/// What the pointer is over, shared by the treemap, its caption and the
/// list beside it. Only the views that read it redraw when it changes; the
/// tiles never do.
@Observable
@MainActor
final class StorageHover {
    /// Where the pointer is.
    enum Source {
        case treemap
        case list
    }

    /// The item under the pointer, in the treemap or the list.
    private(set) var item: Int?
    /// Inside a folder's tile: the item drawn in it under the pointer.
    private(set) var inner: Int?
    /// Which view `item` came from: the list follows the treemap, not itself.
    private(set) var source = Source.list
    /// The item picked in the Largest Files or Changes list (or what stands
    /// for it), as the items from the scanned folder down to it, so the
    /// treemap can outline the tile holding it in whichever folder is open.
    private(set) var marked: [Int] = []
    /// The file picked in the Largest Files list.
    private(set) var markedFile: String?
    /// The change picked in the Changes list (a `DiskSizeChange.id`).
    private(set) var markedChange: String?
    /// What was picked, for the tag on its outline in the treemap.
    private(set) var pick: StoragePick?

    func enter(_ id: Int?, inner: Int? = nil, from source: Source = .list) {
        if self.source != source { self.source = source }
        if item != id { item = id }
        if self.inner != inner { self.inner = inner }
    }

    /// Clears the hover, unless the pointer has already moved on to another item.
    func leave(_ id: Int) {
        guard item == id else { return }
        item = nil
        inner = nil
    }

    /// Marks the item at `path` in `usage`: itself, or what stands for it
    /// there (see `DiskUsage.closestItem`), picked as a file or a change.
    /// `figure` is its size or change, `direction` which way that went.
    func mark(_ path: String, exists: Bool, in usage: DiskUsage, figure: String, direction: DiskSizeChange.Direction? = nil,
              file: String? = nil, change: String? = nil) {
        let closest = usage.closestItem(to: path, exists: exists)
        let chain = usage.ancestry(of: closest.id).map(\.id)
        let pick = StoragePick(path: path, figure: figure, direction: direction, exists: exists,
                               isKept: closest.kind != .smallerItems && usage.path(of: closest.id) == path)
        if marked != chain { marked = chain }
        if markedFile != file { markedFile = file }
        if markedChange != change { markedChange = change }
        if self.pick != pick { self.pick = pick }
    }

    func clearMarks() {
        if !marked.isEmpty { marked = [] }
        if markedFile != nil { markedFile = nil }
        if markedChange != nil { markedChange = nil }
        if pick != nil { pick = nil }
    }
}

/// The item picked in a list, as the treemap's tag for it names it.
struct StoragePick: Equatable {
    /// Its full path.
    let path: String
    /// Its size, or how it changed ("+150 MB").
    let figure: String
    /// Which way it changed, in Changes mode.
    let direction: DiskSizeChange.Direction?
    /// Still there: something removed is outlined by the folder it was in.
    let exists: Bool
    /// The scan kept it as an item of its own, so a tile can be exactly it.
    let isKept: Bool

    var name: String { (path as NSString).lastPathComponent }
}
