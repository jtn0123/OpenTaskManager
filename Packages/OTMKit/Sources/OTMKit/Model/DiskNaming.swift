import Foundation

/// What to call a disk ahead of its device name ("disk0"): the volume
/// people know it by, or for a disk image, the image's own name.
public enum DiskNaming {
    /// A mounted volume and the whole disk it's stored on.
    public struct Volume: Sendable, Equatable {
        public var name: String
        /// "disk0": the whole disk under the volume, its containers and partitions.
        public var disk: String
        /// The startup volume.
        public var isRoot: Bool
        /// Shown in the Finder. System volumes (Preboot, VM, an asset's
        /// cryptex) are mounted hidden.
        public var isBrowsable: Bool

        public init(name: String, disk: String, isRoot: Bool, isBrowsable: Bool) {
            self.name = name
            self.disk = disk
            self.isRoot = isRoot
            self.isBrowsable = isBrowsable
        }
    }

    /// The name for `disk`: the startup volume's when it's stored there
    /// ("Macintosh HD"); otherwise the volumes on it the Finder shows
    /// ("Backup", "Backup, Media", "Backup and 2 more"). A disk image with
    /// none of those takes its file's name, then a hidden volume's. Nil when
    /// nothing names the disk better than its device.
    public static func name(of disk: String, volumes: [Volume], imagePath: String?) -> String? {
        let mine = volumes.filter { $0.disk == disk && !$0.name.isEmpty }
        if let root = mine.first(where: \.isRoot) { return root.name }
        var shown: [String] = []
        for volume in mine.filter(\.isBrowsable).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            where !shown.contains(volume.name) {
            shown.append(volume.name)
        }
        switch shown.count {
        case 0: break
        case 1: return shown[0]
        case 2: return "\(shown[0]), \(shown[1])"
        default: return "\(shown[0]) and \(shown.count - 1) more"
        }
        if let imagePath, let file = imageName(imagePath) { return file }
        guard imagePath != nil else { return nil }
        return mine.first?.name
    }

    /// "Firefox 131" for "/Users/me/Downloads/Firefox 131.dmg": the file's
    /// name without its extension. Nil for a path with no file name.
    static func imageName(_ path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        guard !file.isEmpty, file != "/" else { return nil }
        let name = (file as NSString).deletingPathExtension
        return name.isEmpty ? file : name
    }
}
