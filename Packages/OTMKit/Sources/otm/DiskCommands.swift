import Darwin
import Foundation
import OTMKit

/// `otm du --json`: the scanned folder, its biggest children to `--depth`,
/// the largest files and the space by category.
struct DiskUsageReport: Encodable {
    struct Entry: Encodable {
        let name: String
        let kind: String
        let allocatedSize: UInt64
        let logicalSize: UInt64
        let itemCount: Int
        let category: String
        let children: [Entry]?
    }

    struct CategoryEntry: Encodable {
        let category: String
        let title: String
        let allocatedSize: UInt64
    }

    let path: String
    let allocatedSize: UInt64
    let logicalSize: UInt64
    let fileCount: Int
    let folderCount: Int
    let unreadableFolders: Int
    let hardLinkDuplicates: Int
    let seconds: Double
    let children: [Entry]
    let largestFiles: [DiskFile]
    let categories: [CategoryEntry]
    /// With `--changes`, when an earlier scan was saved.
    let changes: DiskChangesReport?
    /// With `--reconcile`.
    let reconciliation: DiskReconciliationReport?

    init(_ usage: DiskUsage, depth: Int, count: Int, changes: DiskChangesReport? = nil, reconciliation: DiskReconciliationReport? = nil) {
        self.changes = changes
        self.reconciliation = reconciliation
        func entries(_ item: DiskItem, depth: Int) -> [Entry] {
            usage.children(of: item).prefix(count).map { child in
                Entry(name: child.kind == .smallerItems ? "\(child.itemCount) smaller items" : child.name, kind: child.kind.rawValue,
                      allocatedSize: child.allocatedSize, logicalSize: child.logicalSize, itemCount: child.itemCount,
                      category: String(describing: child.category),
                      children: depth > 1 && child.isFolder && !child.children.isEmpty ? entries(child, depth: depth - 1) : nil)
            }
        }
        path = usage.rootPath
        allocatedSize = usage.root.allocatedSize
        logicalSize = usage.root.logicalSize
        fileCount = usage.fileCount
        folderCount = usage.folderCount
        unreadableFolders = usage.unreadableFolders
        hardLinkDuplicates = usage.hardLinkDuplicates
        seconds = usage.duration
        children = entries(usage.root, depth: max(depth, 1))
        largestFiles = usage.largestFiles
        categories = usage.categories.filter { $0.allocatedSize > 0 }.map {
            CategoryEntry(category: String(describing: $0.category), title: $0.category.title, allocatedSize: $0.allocatedSize)
        }
    }
}

func diskUsageSummary(_ usage: DiskUsage, depth: Int, count: Int) -> String {
    let root = usage.root
    var lines = [
        "\(usage.rootPath): \(Format.bytes(root.allocatedSize)) on disk, \(Format.bytes(root.logicalSize)) of data"
            + " · \(usage.fileCount.formatted()) files, \(usage.folderCount.formatted()) folders · \(Format.fixed(usage.duration, 1)) s",
        "",
        pad("ON DISK", 10, right: true) + pad("SHARE", 8, right: true) + pad("ITEMS", 11, right: true) + "  NAME",
    ]
    func list(_ item: DiskItem, level: Int) {
        for child in usage.children(of: item).prefix(count) {
            let name: String
            switch child.kind {
            case .folder: name = child.name + "/" + (child.contentsOmitted ? "  (contents not kept)" : child.isUnreadable ? "  (unreadable)" : "")
            case .package, .file: name = child.name
            case .smallerItems: name = "(\(child.itemCount.formatted()) smaller items)"
            }
            let share = Double(child.allocatedSize) / Double(max(root.allocatedSize, 1))
            lines.append(pad(Format.bytes(child.allocatedSize), 10, right: true) + pad(Format.percent(share, digits: 1), 8, right: true)
                + pad(child.kind == .file ? "" : child.itemCount.formatted(), 11, right: true)
                + "  " + String(repeating: "  ", count: level) + name)
            if level + 1 < depth, child.isFolder { list(child, level: level + 1) }
        }
    }
    list(root, level: 0)
    if !usage.largestFiles.isEmpty {
        lines += ["", "Largest files"]
        for file in usage.largestFiles.prefix(min(count, 10)) {
            lines.append(pad(Format.bytes(file.allocatedSize), 10, right: true) + "  " + file.path + (file.isPackage ? "/" : ""))
        }
    }
    lines += ["", "By category"]
    for total in usage.categories where total.allocatedSize > 0 {
        let share = Double(total.allocatedSize) / Double(max(root.allocatedSize, 1))
        lines.append(pad(Format.bytes(total.allocatedSize), 10, right: true) + pad(Format.percent(share), 6, right: true)
            + "  " + total.category.title)
    }
    if usage.unreadableFolders > 0 {
        lines += ["", "\(usage.unreadableFolders.formatted()) folders couldn't be read, so their contents aren't counted."
            + " Give your terminal Full Disk Access to include them."]
    }
    return lines.joined(separator: "\n")
}

/// `otm du --changes --json`: what changed since the last saved scan.
/// Sizes a saved scan only bounds have a `low` and a `high` (none when
/// unknown); growth and shrinkage are only what both scans prove.
struct DiskChangesReport: Encodable {
    struct Size: Encodable {
        let low: UInt64
        let high: UInt64?

        init(_ estimate: DiskSizeEstimate) {
            low = estimate.low
            high = estimate.isBounded ? estimate.high : nil
        }
    }

    struct Change: Encodable {
        let path: String
        let kind: String
        let before: Size
        let after: Size
        let growth: UInt64
        let shrinkage: UInt64
        let exact: Bool

        init(_ change: DiskSizeChange) {
            path = change.path
            kind = String(describing: change.kind)
            before = Size(change.before)
            after = Size(change.after)
            growth = change.growth
            shrinkage = change.shrinkage
            exact = change.isExact
        }
    }

    let since: Date
    let ignoredUnder: UInt64
    let total: Change
    let grew: [Change]
    let shrank: [Change]
    let filesAdded: [Change]
    let filesRemoved: [Change]
    let becameUnreadable: [Change]
    let becameReadable: [Change]

    init(_ comparison: DiskScanComparison, count: Int) {
        let threshold = DiskScanComparison.noiseFloor(for: comparison.later.allocatedSize)
        let report = comparison.report(limit: count, ignoringUnder: threshold)
        since = comparison.earlier.scannedAt
        ignoredUnder = threshold
        total = Change(report.total)
        grew = report.grew.map(Change.init)
        shrank = report.shrank.map(Change.init)
        filesAdded = report.filesAdded.map(Change.init)
        filesRemoved = report.filesRemoved.map(Change.init)
        becameUnreadable = report.becameUnreadable.map(Change.init)
        becameReadable = report.becameReadable.map(Change.init)
    }
}

func diskChangesSummary(_ comparison: DiskScanComparison, count: Int) -> String {
    let threshold = DiskScanComparison.noiseFloor(for: comparison.later.allocatedSize)
    let report = comparison.report(limit: count, ignoringUnder: threshold)
    let total = report.total
    let direction = total.direction(ignoringUnder: threshold)
    let amount = switch direction {
    case .grew: Format.byteChange(total.growth, grew: true, exact: total.isExact)
    case .shrank: Format.byteChange(total.shrinkage, grew: false, exact: total.isExact)
    case .same: "no change"
    case .unclear: "can't tell"
    }
    var lines = ["", "Changes since \(comparison.earlier.scannedAt.formatted(date: .abbreviated, time: .shortened)): \(amount)"
        + " (\(Format.bytes(total.before)) → \(Format.bytes(total.after)))"]
    func section(_ title: String, _ changes: [DiskSizeChange], grew: Bool?) {
        guard !changes.isEmpty else { return }
        lines += ["", title]
        for change in changes {
            let figure = grew.map { Format.byteChange($0 ? change.growth : change.shrinkage, grew: $0, exact: change.isExact) } ?? ""
            let suffix = change.kind == .file ? "" : "/"
            let note = change.isNew && change.before.isExact ? "  (new)" : change.isGone && change.after.isExact ? "  (removed)" : ""
            lines.append(pad(figure, 18, right: true) + "  " + change.path + suffix + note)
        }
    }
    section("Grew", report.grew, grew: true)
    section("Shrank", report.shrank, grew: false)
    section("Large files added", report.filesAdded, grew: true)
    section("Large files removed", report.filesRemoved, grew: false)
    section("Couldn't be read this time (not counted as space freed)", report.becameUnreadable, grew: nil)
    section("Could be read this time (not counted as growth)", report.becameReadable, grew: nil)
    if report.isEmpty { lines.append("Nothing changed by more than \(Format.bytes(threshold)).") }
    return lines.joined(separator: "\n")
}

func diskUsageCommand(_ options: Options) {
    let path = ((options.positional.first ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
    // FileManager borrows this local directory flag only until the call returns.
    var isFolder: ObjCBool = false
    guard unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { fail("no folder at \(path)") }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let request = url.path == "/" ? DiskScanRequest.volume(mountPoint: "/", isRoot: true) : DiskScanRequest(root: url)
    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    guard let usage = DiskUsageScanner.scan(request, progress: { progress in
        guard showsProgress else { return }
        let line = "Scanning: \(progress.itemCount.formatted()) items, \(Format.bytes(progress.allocatedSize))"
        FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
    }) else { fail("scan cancelled") }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    var comparison: DiskScanComparison?
    if options.changes {
        // The same history the Storage page keeps, so either can follow the other.
        let summary = DiskScanSummary(usage, scope: DiskScanScope(usage, request: request))
        let history = DiskScanHistory()
        let earlier = history.summaries(of: summary.scope).first { $0.scannedAt < summary.scannedAt }
        do {
            try history.save(summary)
        } catch {
            FileHandle.standardError.write(Data("otm: couldn't save this scan: \(error.localizedDescription)\n".utf8))
        }
        comparison = earlier.map { DiskScanComparison(earlier: $0, later: summary) }
    }
    let reconciliation = options.reconcile ? DiskReconciliationReader.read(usage, request: request) : nil
    if options.json {
        printJSON(DiskUsageReport(usage, depth: options.depth, count: options.count,
                                  changes: comparison.map { DiskChangesReport($0, count: options.count) },
                                  reconciliation: reconciliation.map(DiskReconciliationReport.init)))
    } else {
        print(diskUsageSummary(usage, depth: options.depth, count: options.count))
        if let comparison {
            print(diskChangesSummary(comparison, count: options.count))
        } else if options.changes {
            print("\nNo earlier scan of this folder was saved. This one is, so the next `otm du --changes` can compare with it.")
        }
        if let reconciliation { print(diskReconciliationSummary(reconciliation)) }
    }
}
