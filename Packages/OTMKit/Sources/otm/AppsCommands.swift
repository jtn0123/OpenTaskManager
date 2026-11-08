import Foundation
import OTMKit
import os

/// An installed app with its disk space, flattened into one JSON object.
struct AppReport: Encodable {
    enum Key: String, CodingKey { case allocatedBytes }

    let app: InstalledApp
    let allocatedBytes: UInt64?

    func encode(to encoder: any Encoder) throws {
        try app.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(allocatedBytes, forKey: .allocatedBytes)
    }
}

func appTable(_ apps: [InstalledApp], sizes: [String: UInt64]?) -> String {
    let day = Date.ISO8601FormatStyle().year().month().day()
    var lines = [
        pad("NAME", 30) + pad("VERSION", 16) + pad("KIND", 12) + pad("ARCH", 14) + pad("SIGNER", 14) + pad("OPENED", 11)
            + (sizes == nil ? "" : pad("SIZE", 10, right: true)) + "  STARTS",
    ]
    for app in apps {
        lines.append(
            pad(app.name, 30) + pad(app.versionText, 16) + pad(app.kind.title, 12) + pad(app.architecture.title, 14)
                + pad(app.signature.signer.title, 14) + pad(app.lastOpened.map { $0.formatted(day) } ?? "-", 11)
                + (sizes.map { pad($0[app.id].map(Format.bytes) ?? "-", 10, right: true) } ?? "")
                + "  " + (app.startsItself ? "yes" : "")
        )
    }
    return lines.joined(separator: "\n")
}

func appsCommand(_ options: Options) {
    let apps = InstalledApps.scan()
    var sizes: [String: UInt64]?
    if options.sizes {
        let measured = OSAllocatedUnfairLock(initialState: [String: UInt64]())
        BoundedWork.forEach(apps.map(\.resolvedPath), width: 4) { path in
            if let size = InstalledApps.allocatedSize(ofBundleAt: path) { measured.withLock { $0[path] = size } }
        }
        sizes = measured.withLock { $0 }
    }
    if options.json {
        printJSON(apps.map { AppReport(app: $0, allocatedBytes: sizes?[$0.id]) })
    } else {
        print(appTable(apps, sizes: sizes))
        let intel = apps.filter { $0.architecture == .intel }.count
        var footer = "\n\(apps.count) apps"
        if intel > 0 { footer += ", \(intel) Intel only (run under Rosetta)" }
        if let sizes { footer += ", \(Format.bytes(sizes.values.reduce(0, +))) on disk" }
        print(footer)
    }
}
