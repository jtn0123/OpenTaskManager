@testable import OTMKit
import Testing

struct DriversStatusFilterTests {
    @Test func loadedIncludesRunningSystemExtensionsAndKextsThatHaveNotStarted() {
        for status: ExtensionStatus in [.active, .loaded, .notStarted] {
            #expect(DriversStatusFilter.loaded.includes(status))
            #expect(!DriversStatusFilter.notInUse.includes(status))
        }
    }

    @Test func copiesWithUnknownUseAndRegisteredInactiveExtensionsAreNotCalledLoaded() {
        for status: ExtensionStatus in [.notInUse, .useUnknown, .needsApproval, .enabled, .disabled, .uninstalling, .other("waiting")] {
            #expect(!DriversStatusFilter.loaded.includes(status))
            #expect(DriversStatusFilter.all.includes(status))
            #expect(DriversStatusFilter.notInUse.includes(status) == (status == .notInUse))
        }
    }

    @Test func summaryCardsChooseTheirMatchingStatus() {
        #expect(DriverSummaryFilter.kernel.status == .loaded)
        #expect(DriverSummaryFilter.thirdPartyKernel.status == .loaded)
        #expect(DriverSummaryFilter.notInUse.status == .notInUse)
        #expect(DriverSummaryFilter.system.status == .all)
        #expect(DriverSummaryFilter.attention.status == .all)
    }

    @Test func summaryPredicatesDescribeTheirCountsWithBothPublishers() {
        let apple = kext("com.apple.example")
        let thirdParty = kext("com.example.driver")
        let active = system(active: true, state: "activated enabled")
        let approval = system(active: false, state: "waiting for user")
        let bundle = ExtensionBundle(path: "/Library/Extensions/Example.kext", appPath: nil, category: .kernel,
                                     bundleID: "com.example.driver", name: "Example", version: "1", build: "1",
                                     teamID: nil, signer: .unsigned)
        let copy = ExtensionItem(bundle)
        let unknown = ExtensionItem(bundle, unknown: .listUnavailable)
        let items = [apple, thirdParty, active, approval, copy, unknown]
        let summary = ExtensionSummary(items)
        #expect(items.filter(DriverSummaryFilter.system.includes).count == summary.systemExtensions)
        #expect(items.filter(DriverSummaryFilter.thirdPartyKernel.includes).count == summary.thirdPartyKernelExtensions)
        #expect(items.filter(DriverSummaryFilter.kernel.includes).count == summary.loadedKernelExtensions)
        #expect(items.filter(DriverSummaryFilter.notInUse.includes).count == summary.notInUse)
        #expect(items.filter(DriverSummaryFilter.attention.includes).count == summary.needsAttention)
        #expect(items.filter { $0.publisher == .apple && DriversStatusFilter.loaded.includes($0.status) } == [apple])
        // A card's rows under the vendor it asks for, as the table filters
        // them, are the ones its count counts.
        let counts: [(DriverSummaryFilter, Int)] = [
            (.system, summary.systemExtensions), (.thirdPartyKernel, summary.thirdPartyKernelExtensions),
            (.kernel, summary.loadedKernelExtensions), (.notInUse, summary.notInUse), (.attention, summary.needsAttention),
        ]
        for (card, count) in counts {
            let rows = items.filter { card.vendor.includes($0) && card.status.includes($0.status) && card.includes($0) }
            #expect(rows.count == count, "\(card)")
        }
        #expect(!DriversFilter.thirdParty.covers(DriverSummaryFilter.kernel.vendor))
        #expect(DriversFilter.thirdParty.covers(DriverSummaryFilter.thirdPartyKernel.vendor))
        #expect(DriversFilter.all.covers(.apple))
        #expect(DriversFilter.thirdParty.title(in: items) == "Third party (5)")
        #expect(DriversFilter.all.title(in: items) == "All (6)")
        #expect(items.filter { $0.publisher == .thirdParty && DriversStatusFilter.notInUse.includes($0.status) } == [copy])
    }

    private func kext(_ identifier: String) -> ExtensionItem {
        ExtensionItem(KernelExtension(loadTag: 1, bundleID: identifier, version: "1", references: 0, loadAddress: nil,
                                      size: 0, wiredSize: 0, uuid: nil, linkedAgainst: [], path: nil,
                                      isInterface: false, isStarted: true))
    }

    private func system(active: Bool, state: String) -> ExtensionItem {
        ExtensionItem(SystemExtension(bundleID: "com.example.system", name: "Example", version: "1", build: "1", teamID: nil,
                                      categoryIdentifier: "com.apple.system_extension.network_extension", settingsLocation: nil,
                                      isEnabled: true, isActive: active, state: state, appPath: nil), id: state)
    }
}
