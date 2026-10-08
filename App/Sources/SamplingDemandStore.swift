import OTMKit

/// View lifetimes share the samplers without following the selected page:
/// another window can still need a source after this one leaves it.
@MainActor
final class SamplingDemandStore {
    private var demand = SamplingDemand()

    func contains(_ source: SamplingDemand.Source) -> Bool { demand.contains(source) }
    func add(_ source: SamplingDemand.Source) { demand.add(source) }
    func remove(_ source: SamplingDemand.Source) { demand.remove(source) }
}
