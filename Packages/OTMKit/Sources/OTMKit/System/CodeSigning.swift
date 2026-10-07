import Foundation
import Security

/// Who signed an app, judged from its certificate chain.
public enum AppSigner: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    /// Apple's own software, signed by Apple's code signing authority.
    case apple
    /// Re-signed by Apple for the Mac App Store (or, for iPhone and iPad apps, the App Store).
    case appStore
    /// A Developer ID certificate: a registered developer's app from outside the App Store.
    case developerID
    /// A development or distribution certificate meant for testing, not for handing out.
    case development
    /// A certificate Apple didn't issue, such as a self-signed one.
    case otherCertificate
    /// Signed with no identity at all, as the linker does for local builds.
    case adHoc
    case unsigned
    /// The signature couldn't be read.
    case unknown

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: "Developer ID"
        case .development: "Development"
        case .otherCertificate: "Other certificate"
        case .adHoc: "Ad hoc"
        case .unsigned: "Unsigned"
        case .unknown: "Unknown"
        }
    }

    /// One line on what the signer means for whoever runs the app.
    public var explanation: String {
        switch self {
        case .apple: "Signed by Apple as part of macOS or an Apple app."
        case .appStore: "Signed by Apple when the App Store distributed it."
        case .developerID: "Signed by a developer registered with Apple, for distribution outside the App Store."
        case .development: "Signed with a developer's testing certificate, not one meant for distribution."
        case .otherCertificate: "Signed with a certificate Apple didn't issue."
        case .adHoc: "Signed without an identity, as local builds are, so it doesn't say who made it."
        case .unsigned: "Not signed, so nothing records who made it or whether it changed since."
        case .unknown: "The signature couldn't be read."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// What an app's code signature says, read from the signature alone. The
/// signature isn't validated (that hashes every file in the bundle), and
/// notarization isn't checked, because that needs the same validation.
public struct CodeSignature: Sendable, Codable, Hashable {
    public let signer: AppSigner
    /// The signing identifier, usually the bundle ID.
    public let identifier: String?
    /// The developer's Apple team, such as "EQHXZ8M8AV". Apple's own software has none.
    public let teamIdentifier: String?
    /// Certificate names from the signing certificate up to its root.
    public let authorities: [String]
    /// Signed with the hardened runtime, which notarization requires.
    public let hardenedRuntime: Bool

    public init(signer: AppSigner, identifier: String? = nil, teamIdentifier: String? = nil,
                authorities: [String] = [], hardenedRuntime: Bool = false) {
        self.signer = signer
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.authorities = authorities
        self.hardenedRuntime = hardenedRuntime
    }

    public static let unknown = CodeSignature(signer: .unknown)

    /// The person or company in a developer certificate: "Google LLC" from
    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)". Apple's and the
    /// App Store's certificates don't name the developer.
    public var developerName: String? {
        guard signer == .developerID || signer == .development, let leaf = authorities.first,
              let colon = leaf.range(of: ": ") else { return nil }
        var name = String(leaf[colon.upperBound...])
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        return name.isEmpty ? nil : name
    }
}

/// Reads code signatures with the Security framework.
public enum CodeSigning {
    /// `kSecCodeSignatureAdhoc`.
    static let adHocFlag: UInt32 = 0x0002
    /// `kSecCodeSignatureRuntime`.
    static let runtimeFlag: UInt32 = 0x1_0000

    /// The signature of the bundle or executable at `path`. Reads the
    /// signature and certificates only, so it takes a millisecond or so.
    public static func signature(atPath path: String) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unknown }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return CodeSignature(signer: .unsigned) }
        guard status == errSecSuccess, let dictionary = information as? [String: Any] else { return .unknown }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let authorities = certificates.map { SecCertificateCopySubjectSummary($0) as String? ?? "Unnamed certificate" }
        return signature(signingInformation: dictionary, authorities: authorities)
    }

    /// Classifies what `SecCodeCopySigningInformation` returned, given the
    /// names of its certificates (leaf first).
    public static func signature(signingInformation info: [String: Any], authorities: [String]) -> CodeSignature {
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        return CodeSignature(
            signer: signer(authorities: authorities, flags: flags, identifier: identifier),
            identifier: identifier,
            teamIdentifier: (info[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 },
            authorities: authorities,
            hardenedRuntime: flags & runtimeFlag != 0
        )
    }

    private static let developmentPrefixes = [
        "Apple Development:", "Mac Developer:", "Apple Distribution:", "3rd Party Mac Developer Application:",
    ]

    static func signer(authorities: [String], flags: UInt32, identifier: String?) -> AppSigner {
        guard let leaf = authorities.first else {
            // Unsigned code has no identifier; ad hoc signatures carry one but no certificates.
            if flags & adHocFlag != 0 { return .adHoc }
            return identifier == nil ? .unsigned : .unknown
        }
        guard authorities.count > 1, authorities.last == "Apple Root CA" else { return .otherCertificate }
        // Apple signs macOS itself as "Software Signing" or "macOS Software Signing".
        if leaf.hasSuffix("Software Signing") { return .apple }
        if leaf == "Apple Mac OS Application Signing" || leaf == "Apple iPhone OS Application Signing" { return .appStore }
        if leaf.hasPrefix("Developer ID Application:") { return .developerID }
        if developmentPrefixes.contains(where: leaf.hasPrefix) { return .development }
        return .otherCertificate
    }
}
