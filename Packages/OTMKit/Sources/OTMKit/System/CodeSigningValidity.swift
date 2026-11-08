import Foundation
import Security

public enum CodeSignatureValidity: Sendable, Equatable {
    case valid, unsigned, invalid, unreadable

    public var title: String {
        switch self {
        case .valid: "Valid signature"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid signature"
        case .unreadable: "Not readable"
        }
    }
}

extension CodeSigning {
    /// Validates the executable's contents on demand, without checking online
    /// notarization or asking the user to approve trust. Signer identity alone
    /// does not establish that the signed contents are intact.
    public static func validity(atPath path: String) -> CodeSignatureValidity {
        var code: SecStaticCode?
        // Security borrows the output variable and transfers a successful Create result's retain to Swift.
        guard unsafe SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unreadable }
        let status = SecStaticCodeCheckValidity(code, [], nil)
        switch status {
        case errSecSuccess: return .valid
        case errSecCSUnsigned: return .unsigned
        case errSecCSStaticCodeNotFound: return .unreadable
        default: return .invalid
        }
    }
}
