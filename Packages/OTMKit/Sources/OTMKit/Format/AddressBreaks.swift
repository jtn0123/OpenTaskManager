import Foundation

/// Where to break an IPv6 address that's too long for its column: between
/// its groups, in lines of even length, and never before its prefix, so
/// "/64" can't end up alone on a line. Text wrapping only breaks after the
/// slash, which is exactly where it shouldn't. For the System page's
/// network cards; the app shows the first form that fits. Reverse-DNS
/// names (driver and bundle IDs) break after their dots the same way, since
/// wrapping would otherwise hyphenate one mid-word.
public enum AddressBreaks {
    /// `text` (one address a line, as a network card's value holds them)
    /// broken over more and more lines: the longest IPv6 address in two,
    /// three… even lines, and any other as long in as few as keep within
    /// them. Other lines (IPv4, host names) stay whole. Empty when there's
    /// no IPv6 address to break.
    public static func forms(_ text: String, upTo parts: Int = 4) -> [String] {
        forms(text, upTo: parts, grouping: groups)
    }

    /// `text` (one name a line: "com.apple.CryptoTokenKit.pivtoken 1.0")
    /// broken after the dots of its reverse-DNS names in the same way, with
    /// anything after a name (its version) kept on its last line. Empty
    /// when no line starts with such a name.
    public static func dottedForms(_ text: String, upTo parts: Int = 4) -> [String] {
        forms(text, upTo: parts, grouping: dottedGroups)
    }

    private static func forms(_ text: String, upTo parts: Int, grouping: (String) -> [String]?) -> [String] {
        let lines = text.components(separatedBy: "\n").map { (line: $0, groups: grouping($0)) }
        guard let longest = lines.filter({ $0.groups != nil }).max(by: { $0.line.count < $1.line.count })?.groups else { return [] }
        var forms: [String] = []
        for part in 2...max(parts, 2) where part <= longest.count {
            let width = split(longest[...], into: part).longest
            let form = lines.map { line in
                guard let groups = line.groups, line.line.count > width else { return line.line }
                return self.lines(of: groups, within: width).joined(separator: "\n")
            }.joined(separator: "\n")
            if form != text, !forms.contains(form) { forms.append(form) }
        }
        return forms
    }

    /// An IPv6 address's groups, each with the colon after it and the last
    /// with any zone and prefix ("a90c/64"); a "::" stays with the group
    /// before it, as does a prefix straight after one ("fe80::/10"). Nil for
    /// anything that isn't an IPv6 address.
    static func groups(_ line: String) -> [String]? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":./%"))
        guard line.filter({ $0 == ":" }).count >= 2, line.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let characters = Array(line)
        var groups: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            if character == ":", index + 1 < characters.count, characters[index + 1].isHexDigit {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// A reverse-DNS name's parts ("com.", "apple.", "pivtoken 1.0"), each
    /// with the dot after it and the last with whatever follows the name;
    /// nil unless the line starts with a name of three parts or more (an
    /// IPv4 address or a version number, all digits, isn't one).
    static func dottedGroups(_ line: String) -> [String]? {
        let name = line.prefix { $0 != " " }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard parts.count >= 3, name.contains(where: \.isLetter),
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return parts.dropLast().map { String($0) + "." } + [String(parts[parts.count - 1]) + String(line.dropFirst(name.count))]
    }

    /// `groups` in as few even lines as keep within `width` characters, or
    /// a group a line when even that doesn't.
    static func lines(of groups: [String], within width: Int) -> [String] {
        for count in 1..<max(groups.count, 1) {
            let lines = split(groups[...], into: count)
            if lines.longest <= width { return lines.lines }
        }
        return groups
    }

    /// `groups` in `count` lines, in order, with the longest line as short as it can be.
    private static func split(_ groups: ArraySlice<String>, into count: Int) -> (lines: [String], longest: Int) {
        let count = min(count, groups.count)
        guard count > 1 else {
            let line = groups.joined()
            return ([line], line.count)
        }
        var best: (lines: [String], longest: Int)?
        for cut in (groups.startIndex + 1)...(groups.endIndex - count + 1) {
            let first = groups[groups.startIndex..<cut].joined()
            let rest = split(groups[cut...], into: count - 1)
            let longest = max(first.count, rest.longest)
            if best.map({ longest < $0.longest }) ?? true { best = ([first] + rest.lines, longest) }
        }
        return best ?? ([groups.joined()], groups.joined().count)
    }
}
