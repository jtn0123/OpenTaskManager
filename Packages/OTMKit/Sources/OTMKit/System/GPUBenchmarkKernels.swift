import Foundation
import Metal

// The GPU benchmark's three workloads. Their shaders, inputs, sizes and
// arithmetic are part of `GPUBenchmark.suiteVersion`: change any of them and
// bump it, or results stop comparing with the ones already saved. A test
// pins each workload's answers for the standard configuration to catch that.
//
// A unit of work is one dispatch or one render pass of a fixed size. Each
// unit adds its result to what the units before it left, so after a command
// buffer of N units every output must equal N units' worth of an answer
// worked out beforehand on the CPU: a unit the GPU skipped, or got wrong,
// shows. Every output is checked after every command buffer.

/// The shaders, compiled from source when a run starts, so the benchmark
/// needs no build step of its own and runs the same code in any build.
enum GPUBenchmarkShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ComputeParams {
        uint iterations;
        uint seedGroups;
        float multiplier;
        float addend;
    };

    // Eight independent chains of fused multiply-adds per thread, unrolled
    // eight steps at a time so the loop's own counting stays out of the way.
    // The multiplier and addend come from a buffer, so nothing can be folded
    // away; the chains' bit patterns are added up (integer adds, exact in
    // any order) onto what earlier units left.
    kernel void otm_fma(device const float *seeds [[buffer(0)]],
                        device uint *results [[buffer(1)]],
                        constant ComputeParams &params [[buffer(2)]],
                        uint index [[thread_position_in_grid]]) {
        device const float *seed = seeds + (index % params.seedGroups) * 8;
        float x0 = seed[0], x1 = seed[1], x2 = seed[2], x3 = seed[3];
        float x4 = seed[4], x5 = seed[5], x6 = seed[6], x7 = seed[7];
        const float a = params.multiplier;
        const float b = params.addend;
        #pragma unroll(8)
        for (uint step = 0; step < params.iterations; step++) {
            x0 = fma(x0, a, b); x1 = fma(x1, a, b); x2 = fma(x2, a, b); x3 = fma(x3, a, b);
            x4 = fma(x4, a, b); x5 = fma(x5, a, b); x6 = fma(x6, a, b); x7 = fma(x7, a, b);
        }
        results[index] += as_type<uint>(x0) + as_type<uint>(x1) + as_type<uint>(x2) + as_type<uint>(x3)
            + as_type<uint>(x4) + as_type<uint>(x5) + as_type<uint>(x6) + as_type<uint>(x7);
    }

    struct MemoryParams {
        uint lanes;
        uint rows;
        uint seed;
        uint unused;
    };

    uint otm_mix(uint x) {
        x ^= x >> 16; x *= 0x7feb352du;
        x ^= x >> 15; x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    // Element (row, lane) is the lane's own start plus row steps, so each
    // lane's total has a closed form the CPU works out without the data.
    kernel void otm_fill(device uint4 *data [[buffer(0)]],
                         constant MemoryParams &params [[buffer(1)]],
                         uint index [[thread_position_in_grid]]) {
        uint lane = index % params.lanes;
        uint row = index / params.lanes;
        uint first = lane * 4 + params.seed;
        uint4 start = uint4(otm_mix(first), otm_mix(first + 1), otm_mix(first + 2), otm_mix(first + 3));
        data[index] = start + row * uint4(0x9e3779b9u, 0x85ebca6bu, 0xc2b2ae35u, 0x27d4eb2fu);
    }

    // Each lane reads one 16-byte element per row; neighbouring lanes read
    // neighbouring elements, so every SIMD group reads whole lines.
    kernel void otm_read(device const uint4 *data [[buffer(0)]],
                         device uint4 *sums [[buffer(1)]],
                         constant MemoryParams &params [[buffer(2)]],
                         uint lane [[thread_position_in_grid]]) {
        uint4 sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0;
        device const uint4 *column = data + lane;
        uint stride = params.lanes;
        for (uint row = 0; row < params.rows; row += 4) {
            sum0 += column[(row + 0) * stride];
            sum1 += column[(row + 1) * stride];
            sum2 += column[(row + 2) * stride];
            sum3 += column[(row + 3) * stride];
        }
        sums[lane] += (sum0 + sum1) + (sum2 + sum3);
    }

    struct LayerVertex {
        float4 position [[position]];
    };

    // One triangle that covers the whole target; each instance is a layer.
    vertex LayerVertex otm_layer_vertex(uint vertexID [[vertex_id]]) {
        float2 corner = float2(float((vertexID << 1) & 2), float(vertexID & 2));
        LayerVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Blended additively, so no layer hides another and each one counts.
    fragment float4 otm_layer_fragment() {
        return float4(1.0);
    }
    """
}

// MARK: - Answers worked out on the CPU

/// FP32 compute: the chains' seeds and each seed group's answer.
struct GPUComputeReference: Sendable {
    /// Floats per seed group: one per chain.
    static let chains = 8
    /// 1 − 2⁻¹², exact in a Float. With the addend, every chain heads for 1
    /// without reaching it in a unit, so its seed matters to the last step.
    static let multiplier: Float = 1 - 1 / 4096
    static let addend: Float = 1 / 4096

    let iterations: Int
    let seeds: [Float]
    /// Per seed group, the sum of its chains' final bit patterns.
    let expected: [UInt32]

    init(groups: Int, iterations: Int, seed: UInt64) {
        self.iterations = max(iterations, 1)
        var random = BenchmarkRandom(state: seed)
        // 0.5..<1.5, 24 random bits: every seed is exact in a Float.
        seeds = (0..<max(groups, 1) * Self.chains).map { _ in 0.5 + Float(random.next() >> 40) / Float(1 << 24) }
        expected = Self.answers(seeds: seeds, iterations: self.iterations)
    }

    /// The same fused steps as the shader, one chain at a time.
    static func answers(seeds: [Float], iterations: Int) -> [UInt32] {
        stride(from: 0, to: seeds.count, by: chains).map { first in
            var sum: UInt32 = 0
            for chain in first..<first + chains {
                var value = seeds[chain]
                for _ in 0..<iterations { value = addend.addingProduct(value, multiplier) }
                sum &+= value.bitPattern
            }
            return sum
        }
    }

    /// Whether every thread's result is `units` times its group's answer.
    func verify(_ results: UnsafeBufferPointer<UInt32>, units: Int) -> Bool {
        let scale = UInt32(truncatingIfNeeded: units)
        let wanted = expected.map { $0 &* scale }
        let groups = wanted.count
        return wanted.withUnsafeBufferPointer { wanted in
            var group = 0
            for value in results {
                if value != wanted[group] { return false }
                group += 1
                if group == groups { group = 0 }
            }
            return true
        }
    }
}

/// Memory: each lane's total over its rows, from the fill's closed form.
struct GPUMemoryReference: Sendable {
    static let steps: [UInt32] = [0x9E37_79B9, 0x85EB_CA6B, 0xC2B2_AE35, 0x27D4_EB2F]

    let lanes: Int
    let rows: Int
    let seed: UInt32
    /// Four words per lane: its sum over every row.
    let expected: [UInt32]

    init(bytes: Int, lanes: Int, seed: UInt64) {
        self.lanes = max(lanes, 1)
        // Whole groups of four rows, as the shader reads them.
        rows = max(bytes / 16 / self.lanes / 4 * 4, 4)
        self.seed = UInt32(truncatingIfNeeded: seed)
        let rows = UInt32(truncatingIfNeeded: rows)
        let triangle = UInt32(truncatingIfNeeded: Int(rows) * (Int(rows) - 1) / 2)
        var expected: [UInt32] = []
        expected.reserveCapacity(self.lanes * 4)
        for lane in 0..<self.lanes {
            for word in 0..<4 {
                let start = Self.start(lane: lane, word: word, seed: self.seed)
                expected.append(start &* rows &+ Self.steps[word] &* triangle)
            }
        }
        self.expected = expected
    }

    /// Bytes one unit reads.
    var bytes: Int { lanes * rows * 16 }

    static func mix(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x &*= 0x7FEB_352D
        x ^= x >> 15
        x &*= 0x846C_A68B
        x ^= x >> 16
        return x
    }

    /// The word the fill puts in row 0 of a lane.
    static func start(lane: Int, word: Int, seed: UInt32) -> UInt32 {
        mix(UInt32(truncatingIfNeeded: lane * 4 + word) &+ seed)
    }

    /// The word the fill puts at (row, lane), for checking the closed form.
    static func element(row: Int, lane: Int, word: Int, seed: UInt32) -> UInt32 {
        start(lane: lane, word: word, seed: seed) &+ UInt32(truncatingIfNeeded: row) &* steps[word]
    }

    /// Whether every lane's sums are `units` times its total.
    func verify(_ sums: UnsafeBufferPointer<UInt32>, units: Int) -> Bool {
        guard sums.count == expected.count else { return false }
        let scale = UInt32(truncatingIfNeeded: units)
        return expected.withUnsafeBufferPointer { expected in
            for index in 0..<expected.count where sums[index] != expected[index] &* scale { return false }
            return true
        }
    }
}

/// Fill rate: every pixel counts the layers blended onto it.
enum GPUFillReference {
    /// A pass's layers stay exact in a 32-bit float up to 2²⁴ in all.
    static func maximumUnits(layers: Int) -> Int {
        max((1 << 24) / max(layers, 1), 1)
    }

    static func verify(_ pixels: UnsafeBufferPointer<Float>, units: Int, layers: Int) -> Bool {
        let wanted = Float(units * layers)
        for pixel in pixels where pixel != wanted { return false }
        return true
    }
}

// MARK: - Running on the GPU

/// The device, queue and compiled pipelines, made once per run before
/// anything is timed.
final class GPUBenchmarkContext {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let fma: any MTLComputePipelineState
    let fill: any MTLComputePipelineState
    let read: any MTLComputePipelineState
    /// The fill workload's pipeline, or why this GPU couldn't build it.
    let layers: Result<any MTLRenderPipelineState, GPUBenchmarkError>

    static let fillFormat = MTLPixelFormat.r32Float

    init(device: any MTLDevice) throws(GPUBenchmarkError) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw .unsupported("it couldn't make a command queue") }
        self.queue = queue
        let options = MTLCompileOptions()
        // IEEE rounding throughout, so the GPU's answers match the CPU's to the bit.
        if #available(macOS 15, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: GPUBenchmarkShaders.source, options: options)
        } catch {
            throw .unsupported("its compiler rejected the shaders: \(error.localizedDescription)")
        }
        func compute(_ name: String) throws(GPUBenchmarkError) -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw .unsupported("the shader \(name) is missing") }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw .unsupported("it couldn't build the \(name) pipeline: \(error.localizedDescription)")
            }
        }
        fma = try compute("otm_fma")
        fill = try compute("otm_fill")
        read = try compute("otm_read")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "otm_layer_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "otm_layer_fragment")
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = Self.fillFormat
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .one
        do {
            layers = try .success(device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            layers = .failure(.unsupported("it couldn't build the blending pipeline: \(error.localizedDescription)"))
        }
    }

    /// Threads per threadgroup for `pipeline`: a power of two up to 256 that
    /// divides the benchmark's thread counts.
    static func groupWidth(_ pipeline: any MTLComputePipelineState) -> Int {
        var width = 256
        while width > 1, width > pipeline.maxTotalThreadsPerThreadgroup { width /= 2 }
        return width
    }

    func buffer(_ length: Int, private isPrivate: Bool = false) throws(GPUBenchmarkError) -> any MTLBuffer {
        guard length <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: max(length, 16), options: isPrivate ? .storageModePrivate : .storageModeShared)
        else { throw .unsupported("it couldn't allocate a \(Format.wholeBytes(UInt64(length))) buffer") }
        return buffer
    }

    /// Commits `buffer` and waits for it, outside any timing.
    func finish(_ buffer: any MTLCommandBuffer, _ workload: GPUWorkload) throws(GPUBenchmarkError) {
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else {
            throw .failed(workload, buffer.error?.localizedDescription ?? "the command buffer didn't complete")
        }
    }
}

/// One workload's buffers and pipeline. `encode` adds units to a command
/// buffer; `reset` clears the outputs before one; `verify` checks them after.
protocol GPUWorkloadRunner: AnyObject {
    var workload: GPUWorkload { get }
    /// Work in one unit, in the workload's measure (floating-point operations, bytes or pixels).
    var workPerUnit: Double { get }
    /// The most units one command buffer may hold before an answer stops being exact.
    var maximumUnits: Int { get }
    func reset()
    func encode(units: Int, into buffer: any MTLCommandBuffer) throws(GPUBenchmarkError)
    func verify(units: Int) throws(GPUBenchmarkError) -> Bool
}

/// FP32 compute: `otm_fma` over every thread, once per unit.
final class GPUComputeRunner: GPUWorkloadRunner {
    let workload = GPUWorkload.compute
    private let context: GPUBenchmarkContext
    private let reference: GPUComputeReference
    private let threads: Int
    private let seeds: any MTLBuffer
    private let results: any MTLBuffer

    init(context: GPUBenchmarkContext, configuration: GPUBenchmarkConfiguration) throws(GPUBenchmarkError) {
        self.context = context
        let reference = GPUComputeReference(groups: configuration.computeSeedGroups, iterations: configuration.computeIterations,
                                            seed: configuration.seed)
        self.reference = reference
        let width = GPUBenchmarkContext.groupWidth(context.fma)
        threads = max(configuration.computeThreads / width, 1) * width
        let seeds = try context.buffer(reference.seeds.count * 4)
        reference.seeds.withUnsafeBytes { seeds.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        self.seeds = seeds
        results = try context.buffer(threads * 4)
    }

    /// Two operations (a multiply and an add) per fused step.
    var workPerUnit: Double { Double(threads) * Double(reference.iterations) * Double(GPUComputeReference.chains) * 2 }
    var maximumUnits: Int { 1 << 20 }

    func reset() {
        results.contents().initializeMemory(as: UInt8.self, repeating: 0, count: threads * 4)
    }

    func encode(units: Int, into buffer: any MTLCommandBuffer) throws(GPUBenchmarkError) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw .failed(workload, "it couldn't start a compute pass") }
        var params = (UInt32(reference.iterations), UInt32(reference.expected.count),
                      GPUComputeReference.multiplier, GPUComputeReference.addend)
        encoder.setComputePipelineState(context.fma)
        encoder.setBuffer(seeds, offset: 0, index: 0)
        encoder.setBuffer(results, offset: 0, index: 1)
        withUnsafeBytes(of: &params) { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        let width = GPUBenchmarkContext.groupWidth(context.fma)
        for _ in 0..<units {
            encoder.dispatchThreadgroups(MTLSize(width: threads / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        encoder.endEncoding()
    }

    func verify(units: Int) -> Bool {
        reference.verify(UnsafeBufferPointer(start: results.contents().assumingMemoryBound(to: UInt32.self), count: threads),
                         units: units)
    }
}

/// Memory: `otm_read` over the whole buffer, once per unit. The buffer is
/// the GPU's alone and filled by `otm_fill` before anything is timed.
final class GPUMemoryRunner: GPUWorkloadRunner {
    let workload = GPUWorkload.memory
    private let context: GPUBenchmarkContext
    private let reference: GPUMemoryReference
    private let data: any MTLBuffer
    private let sums: any MTLBuffer

    init(context: GPUBenchmarkContext, configuration: GPUBenchmarkConfiguration) throws(GPUBenchmarkError) {
        self.context = context
        let width = min(GPUBenchmarkContext.groupWidth(context.read), GPUBenchmarkContext.groupWidth(context.fill))
        reference = GPUMemoryReference(bytes: configuration.memoryBytes, lanes: max(configuration.memoryLanes / width, 1) * width,
                                       seed: configuration.seed)
        data = try context.buffer(reference.bytes, private: true)
        sums = try context.buffer(reference.lanes * 16)
        guard let buffer = context.queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
            throw .failed(workload, "it couldn't start a compute pass")
        }
        var params = parameters
        encoder.setComputePipelineState(context.fill)
        encoder.setBuffer(data, offset: 0, index: 0)
        withUnsafeBytes(of: &params) { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchThreadgroups(MTLSize(width: reference.lanes * reference.rows / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        try context.finish(buffer, workload)
    }

    /// `MemoryParams`: lanes, rows, seed and a spare word, 16 bytes.
    private var parameters: SIMD4<UInt32> {
        SIMD4(UInt32(reference.lanes), UInt32(reference.rows), reference.seed, 0)
    }

    var workPerUnit: Double { Double(reference.bytes) }
    var maximumUnits: Int { 1 << 20 }

    func reset() {
        sums.contents().initializeMemory(as: UInt8.self, repeating: 0, count: reference.lanes * 16)
    }

    func encode(units: Int, into buffer: any MTLCommandBuffer) throws(GPUBenchmarkError) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw .failed(workload, "it couldn't start a compute pass") }
        var params = parameters
        encoder.setComputePipelineState(context.read)
        encoder.setBuffer(data, offset: 0, index: 0)
        encoder.setBuffer(sums, offset: 0, index: 1)
        withUnsafeBytes(of: &params) { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        let width = GPUBenchmarkContext.groupWidth(context.read)
        for _ in 0..<units {
            encoder.dispatchThreadgroups(MTLSize(width: reference.lanes / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        encoder.endEncoding()
    }

    func verify(units: Int) -> Bool {
        reference.verify(UnsafeBufferPointer(start: sums.contents().assumingMemoryBound(to: UInt32.self), count: reference.lanes * 4),
                         units: units)
    }
}

/// Fill rate: a render pass per unit, each blending `fillLayers` full-target
/// triangles onto what the passes before it left in a 32-bit float target.
final class GPUFillRunner: GPUWorkloadRunner {
    let workload = GPUWorkload.fill
    private let context: GPUBenchmarkContext
    private let pipeline: any MTLRenderPipelineState
    private let size: Int
    private let layers: Int
    private let target: any MTLTexture
    private let readback: any MTLBuffer

    init(context: GPUBenchmarkContext, configuration: GPUBenchmarkConfiguration) throws(GPUBenchmarkError) {
        self.context = context
        pipeline = try context.layers.get()
        size = max(configuration.fillSize, 16)
        layers = max(configuration.fillLayers, 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GPUBenchmarkContext.fillFormat, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let target = context.device.makeTexture(descriptor: descriptor) else {
            throw .unsupported("it couldn't make a \(size) × \(size) render target")
        }
        self.target = target
        readback = try context.buffer(size * size * 4)
    }

    var workPerUnit: Double { Double(size) * Double(size) * Double(layers) }
    var maximumUnits: Int { GPUFillReference.maximumUnits(layers: layers) }

    func reset() {}

    func encode(units: Int, into buffer: any MTLCommandBuffer) throws(GPUBenchmarkError) {
        for unit in 0..<units {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = unit == 0 ? .clear : .load
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw .failed(workload, "it couldn't start a render pass")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: layers)
            encoder.endEncoding()
        }
    }

    /// Copies the target out in a command buffer of its own, so the copy isn't timed.
    func verify(units: Int) throws(GPUBenchmarkError) -> Bool {
        guard let buffer = context.queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else {
            throw .failed(workload, "it couldn't copy the image back")
        }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
        blit.endEncoding()
        try context.finish(buffer, workload)
        return GPUFillReference.verify(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Float.self),
                                                           count: size * size), units: units, layers: layers)
    }
}
