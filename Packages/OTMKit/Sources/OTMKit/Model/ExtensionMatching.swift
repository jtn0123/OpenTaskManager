import Foundation

/// Why it can't be told whether macOS uses a copy of an extension found on disk.
public enum ExtensionUseUnknown: String, Sendable, Codable, Hashable {
    /// Its Info.plist couldn't be read, so it has no identifier to match.
    case unreadable
    /// The list it would be in (systemextensionsctl's, or the kernel's
    /// loaded kexts) couldn't be read.
    case listUnavailable
    /// macOS lists one with the same identifier but no version to compare.
    case versionMissing
    /// More than one copy of the version in use is on disk, and macOS
    /// doesn't say which it took.
    case severalCopies
}

/// Matches the extension bundles found on disk to what macOS reported: a
/// system extension's copy by identifier, version and build, a kext's by
/// identifier and `CFBundleVersion`, as each list prints them. Never by
/// identifier alone, so two versions stay two rows.
public enum ExtensionMatching {
    /// The reported rows, each with the copy on disk that's the one in use
    /// attached where there is one, then a row for every other copy: not in
    /// use when nothing of its version is registered or loaded, unknown when
    /// that can't be told.
    public static func merge(_ reported: [ExtensionItem], bundles: [ExtensionBundle],
                             readSystemExtensions: Bool, readKernelExtensions: Bool) -> [ExtensionItem] {
        var items = reported
        var attached = Set<Int>()
        var unknown: [Int: ExtensionUseUnknown] = [:]
        // Rows with a version first, so one without can't hold back a copy
        // another row of the same identifier matches.
        let order = items.indices.sorted { (items[$0].version.isEmpty ? 1 : 0, $0) < (items[$1].version.isEmpty ? 1 : 0, $1) }
        for index in order {
            let row = items[index]
            guard let isKernel = isKernelRow(row) else { continue }
            let candidates = bundles.indices.filter {
                !attached.contains($0) && unknown[$0] == nil && bundles[$0].bundleID == row.bundleID
                    && (bundles[$0].category == .kernel) == isKernel
            }
            guard !candidates.isEmpty else { continue }
            if row.version.isEmpty {
                for candidate in candidates { unknown[candidate] = .versionMissing }
                continue
            }
            let same = candidates.filter { sameVersion(row, bundles[$0]) }
            // Where macOS says which copy it took, that one; otherwise the only one.
            let hinted = pathHint(row).flatMap { hint in same.first { samePath(bundles[$0].path, hint) } }
            if let pick = hinted ?? (same.count == 1 ? same.first : nil) {
                items[index].bundle = bundles[pick]
                attached.insert(pick)
            } else {
                for candidate in same { unknown[candidate] = .severalCopies }
            }
        }
        let copies = bundles.indices.filter { !attached.contains($0) }.map { index -> ExtensionItem in
            let bundle = bundles[index]
            let isKernel = bundle.category == .kernel
            if let reason = unknown[index] { return ExtensionItem(bundle, unknown: reason) }
            if bundle.bundleID == nil { return ExtensionItem(bundle, unknown: .unreadable) }
            if !(isKernel ? readKernelExtensions : readSystemExtensions) { return ExtensionItem(bundle, unknown: .listUnavailable) }
            var versions: [String] = []
            for row in reported where isKernelRow(row) == isKernel && row.bundleID == bundle.bundleID && !row.version.isEmpty {
                if !versions.contains(row.version) { versions.append(row.version) }
            }
            return ExtensionItem(bundle, registeredVersions: versions)
        }
        return items + copies
    }

    /// Whether a reported row is a kext (true) or a system extension (false);
    /// nil for a copy on disk.
    static func isKernelRow(_ item: ExtensionItem) -> Bool? {
        if item.kernelExtension != nil { return true }
        return item.systemExtension != nil ? false : nil
    }

    /// The same version as printed, and for a system extension the same
    /// build where both are known.
    static func sameVersion(_ row: ExtensionItem, _ bundle: ExtensionBundle) -> Bool {
        guard let version = bundle.reportedVersion, version == row.version else { return false }
        if let build = row.systemExtension?.build, let own = bundle.build, build != own { return false }
        return true
    }

    /// Where macOS says the one in use came from: the kernel's path for a
    /// kext, the database's origin for a system extension.
    static func pathHint(_ row: ExtensionItem) -> String? {
        row.kernelExtension?.path ?? row.systemExtension?.originPath
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        InstalledApps.normalized(lhs) == InstalledApps.normalized(rhs)
    }
}

extension ExtensionItem {
    /// What the status means for this row, in a sentence or two: for a copy
    /// on disk, why it isn't in use or why that's unknown; otherwise the
    /// status's own explanation.
    public var statusExplanation: String {
        let isKernel = category == .kernel
        switch status {
        case .notInUse:
            let lead = isKernel
                ? "It's on disk, but the kernel hasn't loaded it, so it isn't running. That's usual for a driver whose "
                    + "hardware isn't attached, a kext that was never allowed, or one left from an old install."
                : "Its app carries it, but macOS hasn't registered it, so it isn't running. The app may not have "
                    + "asked to turn it on, or may not need it on this Mac."
            guard let versions = registeredVersions, !versions.isEmpty else { return lead }
            let own = bundle?.reportedVersion
            if let own, versions.contains(own) { return lead + " Another copy of version \(own) is the one in use." }
            let list = Self.list(versions)
            let tail = own.map { ", not this copy's \($0)." } ?? "."
            return lead + (isKernel ? " The kernel has version \(list) loaded" : " macOS has version \(list) registered") + tail
        case .useUnknown:
            switch unknownReason {
            case .unreadable?:
                return "It's on disk, but its Info.plist couldn't be read, so it can't be matched to what macOS uses."
            case .listUnavailable?:
                return isKernel
                    ? "It's on disk, but the kernel's list of loaded kexts couldn't be read, so whether it's loaded is unknown."
                    : "It's on disk, but systemextensionsctl didn't answer, so whether macOS has it registered is unknown."
            case .versionMissing?:
                return "macOS lists one with this identifier but no version, so whether this copy is the one in use is unknown."
            case .severalCopies?:
                return "macOS has this version in use and more than one copy of it is on disk. Which one it took is unknown."
            case nil:
                return status.explanation
            }
        default:
            return status.explanation
        }
    }

    /// "1.0", "1.0 and 1.1", "1.0, 1.1 and 1.2".
    private static func list(_ versions: [String]) -> String {
        guard versions.count > 1, let last = versions.last else { return versions.first ?? "" }
        return versions.dropLast().joined(separator: ", ") + " and " + last
    }
}
