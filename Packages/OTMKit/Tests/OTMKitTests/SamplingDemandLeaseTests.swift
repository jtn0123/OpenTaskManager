@testable import OTMKit
import Testing

struct SamplingDemandLeaseTests {
    @Test func repeatedVisibilityNoticesAndStopsStayBalanced() {
        var lease = SamplingDemandLease()
        #expect(lease.release() == nil)
        #expect(update(&lease) == .add)
        #expect(update(&lease) == nil)
        #expect(lease.release() == .remove)
        #expect(lease.release() == nil)
        #expect(update(&lease) == .add)
    }

    @Test(arguments: 0..<5)
    func eachReasonForInvisibilityReleasesExactlyOnce(reason: Int) {
        var lease = SamplingDemandLease()
        #expect(update(&lease) == .add)
        #expect(update(&lease, blockedBy: reason) == .remove)
        #expect(update(&lease, blockedBy: reason) == nil)
        #expect(update(&lease) == .add)
    }

    @Test func invisibleViewsNeverAcquireDemand() {
        for reason in 0..<5 {
            var lease = SamplingDemandLease()
            #expect(update(&lease, blockedBy: reason) == nil)
            #expect(lease.release() == nil)
        }
    }

    private func update(_ lease: inout SamplingDemandLease, blockedBy reason: Int? = nil) -> SamplingDemandLease.Change? {
        lease.update(
            enabled: reason != 0, windowVisible: reason != 1, miniaturized: reason == 2,
            hidden: reason == 3, hasVisibleRoom: reason != 4
        )
    }
}
