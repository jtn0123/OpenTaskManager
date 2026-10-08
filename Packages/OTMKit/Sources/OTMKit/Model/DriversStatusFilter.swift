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
