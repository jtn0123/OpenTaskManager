/// Status and vendor are independent so copies on disk can be found for either publisher.
public enum DriversStatusFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case loaded = "Loaded"
    case notInUse = "Not in use"

    public var id: String { rawValue }

    public func includes(_ status: ExtensionStatus) -> Bool {
        switch self {
        case .all: true
        case .loaded: status == .active || status == .loaded || status == .notStarted
        case .notInUse: status == .notInUse
        }
    }
}

/// Which publishers the Drivers table lists. All by default: third party
/// sorts first, so what was added to macOS leads either way.
extension DriversFilter {
    public func includes(_ item: ExtensionItem) -> Bool {
        switch self {
        case .thirdParty: item.publisher == .thirdParty
        case .apple: item.publisher == .apple
        case .all: true
        }
    }

    /// Whether every row `other` lists is listed here too.
    public func covers(_ other: DriversFilter) -> Bool {
        self == .all || self == other
    }

    /// The vendor picker's segment: "Third party (2)".
    public func title(in items: [ExtensionItem]) -> String {
        "\(rawValue) (\(items.filter(includes).count))"
    }
}

/// A summary narrows the status to the extensions its count describes.
public enum DriverSummaryFilter: Sendable {
    case system, thirdPartyKernel, kernel, notInUse, attention

    public var status: DriversStatusFilter {
        switch self {
        case .thirdPartyKernel, .kernel: .loaded
        case .notInUse: .notInUse
        case .system, .attention: .all
        }
    }

    /// The vendors its count takes in: every card but Third-party kexts counts
    /// Apple's too, so a table narrowed to third party can't show its rows.
    public var vendor: DriversFilter {
        self == .thirdPartyKernel ? .thirdParty : .all
    }

    public func includes(_ item: ExtensionItem) -> Bool {
        switch self {
        case .system: item.systemExtension != nil
        case .thirdPartyKernel: item.kernelExtension != nil && item.publisher == .thirdParty
        case .kernel: item.kernelExtension != nil
        case .notInUse: item.status == .notInUse
        case .attention: item.status.needsAttention
        }
    }
}
