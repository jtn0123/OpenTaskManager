import Foundation

/// Parses `systemextensionsctl list`, and matches each extension with the app
/// that installed it.
enum SystemExtensionList {
    /// systemextensionsd's database. It isn't documented, but it's readable by
    /// everyone and names each extension's app, so it's only used for that.
    static let databasePath = "/Library/SystemExtensions/db.plist"

    /// The listing starts with a count such as "1 extension(s)", even when
    /// there are none, which tells an empty list from a tool that failed.
    static func isListing(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            line.hasSuffix(" extension(s)") && Int(line.split(separator: " ").first ?? "") != nil
        }
    }

    /// Reads the listing: a `--- <category> (Go to '<settings path>' …)` line
    /// starts each category, a header names the columns, then each row has
    /// tab-separated enabled and active marks (`*` or empty), the Team ID,
    /// `bundleID (version/build)`, the name and `[state]`.
    static func parse(_ output: String) -> [SystemExtension] {
        var category = ""
        var settingsLocation: String?
        var extensions: [SystemExtension] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("--- ") {
                category = line.dropFirst(4).split(separator: " ").first.map(String.init) ?? ""
                settingsLocation = quoted(in: line)
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // The column header starts with "enabled"; the count line has no tabs.
            guard fields.count >= 6, fields[0] != "enabled" else { continue }
            let (bundleID, versions) = splitVersion(fields[3])
            guard !bundleID.isEmpty else { continue }
            let versionParts = versions?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
            let state = fields[fields.count - 1]
            extensions.append(SystemExtension(
                bundleID: bundleID,
                // A name with a tab in it would spill into the next field.
                name: fields[4 ..< fields.count - 1].joined(separator: " ").trimmingCharacters(in: .whitespaces),
                version: versionParts.first.flatMap { $0.isEmpty ? nil : $0 },
                build: versionParts.count > 1 ? versionParts[1] : nil,
                teamID: fields[2].isEmpty || fields[2] == "-" ? nil : fields[2],
                categoryIdentifier: category,
                settingsLocation: settingsLocation,
                isEnabled: fields[0] == "*",
                isActive: fields[1] == "*",
                state: state.hasPrefix("[") && state.hasSuffix("]") ? String(state.dropFirst().dropLast()) : state,
                appPath: nil
            ))
        }
        return extensions
    }

    /// "io.example.ext (1.2/120)" becomes the bundle ID and "1.2/120".
    static func splitVersion(_ field: String) -> (bundleID: String, version: String?) {
        guard field.hasSuffix(")"), let open = field.range(of: " (", options: .backwards) else {
            return (field, nil)
        }
        return (String(field[..<open.lowerBound]), String(field[open.upperBound...].dropLast()))
    }

    /// The text between the first pair of single quotes, which is where the
    /// category line names its System Settings pane.
    private static func quoted<S: StringProtocol>(in line: S) -> String? {
        let parts = line.split(separator: "'", omittingEmptySubsequences: false)
        return parts.count >= 3 && !parts[1].isEmpty ? String(parts[1]) : nil
    }

    /// Fills in each extension's app from the database's `container.bundlePath`.
    /// Anything unexpected in the file leaves the paths empty.
    static func attachApps(_ extensions: [SystemExtension], database: Data) -> [SystemExtension] {
        guard let plist = try? PropertyListSerialization.propertyList(from: database, format: nil) as? [String: Any],
              let entries = plist["extensions"] as? [[String: Any]] else { return extensions }
        var apps: [String: String] = [:]
        for entry in entries {
            guard let identifier = entry["identifier"] as? String,
                  let path = (entry["container"] as? [String: Any])?["bundlePath"] as? String, !path.isEmpty else { continue }
            // An update and the copy it replaces come from the same app.
            if apps[identifier] == nil { apps[identifier] = path }
        }
        return extensions.map { item in
            var item = item
            item.appPath = apps[item.bundleID]
            return item
        }
    }
}
