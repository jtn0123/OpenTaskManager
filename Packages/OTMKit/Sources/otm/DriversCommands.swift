import Foundation
import OTMKit

/// System extensions, then kexts, then copies on disk that aren't in use
/// (with where they are), with what needs approval called out.
func extensionTable(_ items: [ExtensionItem]) -> String {
    var lines = [" " + pad("STATUS", 23) + pad("KIND", 21) + pad("PUBLISHER", 13) + pad("VERSION", 14) + "NAME (BUNDLE ID)"]
    for item in items {
        let marker = item.status.needsAttention ? "!" : " "
        var name = "\(item.name) (\(item.bundleID.isEmpty ? "unreadable" : item.bundleID))"
        if item.status.isDiskCopy, let path = item.diskPath { name += "  \(path)" }
        lines.append(marker + pad(item.status.title, 23) + pad(item.kind, 21) + pad(item.publisher.title, 13)
            + pad(item.version.isEmpty ? "-" : item.version, 14) + name)
    }
    return lines.joined(separator: "\n")
}

func driversCommand(_ options: Options) {
    let scan = Extensions.scan()
    let shown = options.all ? scan.items : scan.items.filter { $0.category.isSystemExtension || $0.publisher == .thirdParty }
    if options.json {
        printJSON(shown)
    } else {
        if shown.isEmpty {
            print("No system extensions or third-party kernel extensions are loaded or on disk.")
        } else {
            print(extensionTable(shown))
        }
        var notes: [String] = []
        if !scan.readSystemExtensions { notes.append("System extensions couldn't be read: systemextensionsctl failed.") }
        if !scan.readKernelExtensions { notes.append("Kernel extensions couldn't be read.") }
        let waiting = scan.summary.needsAttention
        if waiting > 0 {
            notes.append("! \(waiting) waiting for approval in System Settings > General > Login Items & Extensions.")
        }
        let unused = shown.filter { $0.status == .notInUse }.count
        if unused > 0 {
            notes.append("\(unused) installed but not in use: on disk, but not registered or loaded, so not running. "
                + "That alone isn't a problem.")
        }
        let unknown = shown.filter { $0.status == .useUnknown }.count
        if unknown > 0 { notes.append("\(unknown) on disk, but whether macOS uses them couldn't be told (--json gives why).") }
        let apple = scan.items.filter { $0.kernelExtension != nil && $0.publisher == .apple }.count
        if !options.all && apple > 0 { notes.append("\(apple) Apple kernel extensions are loaded too (--all lists them).") }
        let appleCopies = scan.items.filter { $0.status.isDiskCopy && $0.category == .kernel && $0.publisher == .apple }.count
        if !options.all && appleCopies > 0 {
            notes.append("\(appleCopies) of Apple's kexts are on disk but not loaded (--all lists them).")
        }
        if !notes.isEmpty { print("\n" + notes.joined(separator: "\n")) }
    }
}
