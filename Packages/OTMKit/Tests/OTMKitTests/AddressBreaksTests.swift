@testable import OTMKit
import Testing

struct AddressBreaksTests {
    private static let address = "fd6c:adbe:19d6:5d7:4d3:55c2:15d6:a90c/64"

    @Test func breaksBetweenGroupsAndKeepsThePrefix() {
        let forms = AddressBreaks.forms(Self.address)
        // Two even lines first: the prefix stays with the last group.
        #expect(forms.first == "fd6c:adbe:19d6:5d7:\n4d3:55c2:15d6:a90c/64")
        for form in forms {
            // Every line but the last ends at a group's colon, so "/64" never stands alone.
            #expect(form.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasSuffix(":") })
            #expect(form.components(separatedBy: "\n").last?.hasSuffix("a90c/64") == true)
            #expect(form.replacingOccurrences(of: "\n", with: "") == Self.address)
        }
        // Narrower forms have more, shorter lines.
        let longest = forms.map { $0.components(separatedBy: "\n").map(\.count).max() ?? 0 }
        #expect(longest == longest.sorted(by: >))
        #expect(forms.count >= 2)
    }

    @Test func compressedGroupsStayTogether() {
        #expect(AddressBreaks.groups("fe80::1%en0/64") == ["fe80::", "1%en0/64"])
        #expect(AddressBreaks.groups("fe80::/10") == ["fe80::/10"])
        #expect(AddressBreaks.groups("2001:db8::8a2e:370:7334/64") == ["2001:", "db8::", "8a2e:", "370:", "7334/64"])
    }

    @Test func otherLinesStayWhole() {
        // IPv4, host names and proxies have nothing to break.
        #expect(AddressBreaks.forms("192.168.64.5/24").isEmpty)
        #expect(AddressBreaks.forms("localdomain\nproxy.example.com:8080").isEmpty)
        // In a list, only the long IPv6 address is broken; the short ones keep their line.
        let forms = AddressBreaks.forms("192.168.1.20/24\n\(Self.address)\nfe80::1")
        #expect(forms.first == "192.168.1.20/24\nfd6c:adbe:19d6:5d7:\n4d3:55c2:15d6:a90c/64\nfe80::1")
    }

    @Test func groupsLongerThanTheLimitGetTheirOwnLine() {
        #expect(AddressBreaks.lines(of: ["fd6c:", "adbe:", "a90c/64"], within: 4) == ["fd6c:", "adbe:", "a90c/64"])
        #expect(AddressBreaks.lines(of: ["fd6c:", "adbe:", "a90c/64"], within: 100) == ["fd6c:adbe:a90c/64"])
    }
}
