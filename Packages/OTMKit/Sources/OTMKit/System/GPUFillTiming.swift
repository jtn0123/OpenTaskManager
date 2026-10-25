import Foundation
import Metal

/// Owned by the fill runner on its benchmark thread. The two slots are reused only after completion and resolution.
final class GPUFillTiming {
    private let device: any MTLDevice
    private let samples: (any MTLCounterSampleBuffer)?
    private var before: GPUTimingEvidence.ClockSample?

    init(device: any MTLDevice) {
        self.device = device
        guard device.supportsCounterSampling(.atStageBoundary),
              let counters = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
            samples = nil
            return
        }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = counters
        descriptor.storageMode = .shared
        descriptor.sampleCount = 2
        // Counter allocation failure qualifies timing; it must not prevent the workload from running.
        samples = try? device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    var unavailableReason: GPUTimingEvidence.Qualification {
        samples == nil ? .noCounterSampling : .counterSamplesUnavailable
    }

    func attach(to pass: MTLRenderPassDescriptor, first: Bool, last: Bool) {
        guard let samples, first || last else { return }
        let attachment = pass.sampleBufferAttachments[0]!
        attachment.sampleBuffer = samples
        attachment.startOfVertexSampleIndex = first ? 0 : MTLCounterDontSample
        attachment.endOfVertexSampleIndex = MTLCounterDontSample
        attachment.startOfFragmentSampleIndex = MTLCounterDontSample
        attachment.endOfFragmentSampleIndex = last ? 1 : MTLCounterDontSample
    }

    func begin() {
        before = samples == nil ? nil : clockSample()
    }

    func end() -> GPUTimingEvidence.Interval? {
        guard let samples else { return nil }
        let after = clockSample()
        guard let data = try? samples.resolveCounterRange(0..<2), data.count == 2 * MemoryLayout<MTLCounterResultTimestamp>.stride else {
            return nil
        }
        // The closure borrows only the two records checked above and does not let their pointers escape.
        return unsafe data.withUnsafeBytes { bytes in
            // Resolution owns both complete timestamp records for this call; unaligned loads avoid assuming Data's alignment.
            let first = unsafe bytes.loadUnaligned(as: MTLCounterResultTimestamp.self).timestamp
            let last = unsafe bytes.loadUnaligned(fromByteOffset: MemoryLayout<MTLCounterResultTimestamp>.stride,
                                                   as: MTLCounterResultTimestamp.self).timestamp
            return GPUTimingEvidence.counterInterval(start: first, end: last, before: before, after: after)
        }
    }

    private func clockSample() -> GPUTimingEvidence.ClockSample {
        let timestamps = device.sampleTimestamps()
        return GPUTimingEvidence.ClockSample(cpuNanoseconds: timestamps.0, gpuTicks: timestamps.1)
    }
}
