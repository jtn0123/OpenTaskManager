import Foundation

// The benchmark's three workloads. Their inputs, sizes and arithmetic are
// part of `CPUBenchmark.suiteVersion`: change any of them and bump it, or
// results stop comparing with the ones already saved. A test pins each
// workload's checksum for the standard configuration to catch that.
//
// Each workload's inputs are made once per run and only read by its
// workers. A worker runs numbered units of work, and every unit's result
// is checked against an answer worked out beforehand by a separate plain
// loop, so nothing can be optimised away and a wrong result stops the run.
// A unit's path through its data depends on its number, so no two units in
// a row repeat the same work.

/// SplitMix64, for the workloads' inputs. The benchmark keeps its own copy
/// so its inputs can't change with another feature's generator.
struct BenchmarkRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// Evenly spread in -1..<1, with 52 bits of the next value.
    mutating func nextSigned() -> Double {
        Double(Int64(bitPattern: next()) >> 11) / Double(1 << 52)
    }
}

/// One workload's shared inputs. Workers come from `makeWorker`, one per
/// thread; the kernel itself is only read once made, which is what makes
/// sharing it between threads safe.
protocol BenchmarkKernel: AnyObject, Sendable {
    /// Work in one unit, in the workload's own measure (bytes or floating-point operations).
    var workPerUnit: Double { get }
    func makeWorker(_ index: Int, of count: Int) -> any BenchmarkWorker
}

/// The state one thread runs units with. Used by that thread alone.
protocol BenchmarkWorker: AnyObject, Sendable {
    /// Runs unit `index` and says whether its result was the expected one.
    func run(unit index: Int) -> Bool
}

// MARK: - Integer

/// Integer: a 64-bit multiply–xor–shift hash over a buffer that stays in the
/// core's caches, in 64-byte blocks. Each block's hash starts from its own
/// number and takes in its 8 words one after another; a unit adds up every
/// block's hash, starting at a block that moves with the unit's number.
/// The sum doesn't depend on that starting point, so every unit's must
/// match the one worked out in order.
final class HashKernel: BenchmarkKernel, BenchmarkWorker, @unchecked Sendable {
    static let blockWords = 8

    private let words: UnsafeMutableBufferPointer<UInt64>
    private let blockCount: Int
    let expected: UInt64

    init(bytes: Int, seed: UInt64) {
        blockCount = max(bytes / 8 / Self.blockWords, 1)
        words = .allocate(capacity: blockCount * Self.blockWords)
        var random = BenchmarkRandom(state: seed)
        for index in words.indices { words[index] = random.next() }
        var sum: UInt64 = 0
        for block in 0..<blockCount { sum &+= Self.hash(words.baseAddress!, block: block) }
        expected = sum
    }

    deinit { words.deallocate() }

    var workPerUnit: Double { Double(words.count * 8) }

    func makeWorker(_ index: Int, of count: Int) -> any BenchmarkWorker { self }

    @inline(__always)
    static func hash(_ words: UnsafePointer<UInt64>, block: Int) -> UInt64 {
        var state = UInt64(truncatingIfNeeded: block) &* 0xD6E8_FEB8_6659_FD93 ^ 0x2545_F491_4F6C_DD1D
        let first = block * blockWords
        for offset in 0..<blockWords {
            state = (state ^ words[first + offset]) &* 0xFF51_AFD7_ED55_8CCD
            state ^= state >> 29
        }
        return state
    }

    func run(unit index: Int) -> Bool {
        let base = UnsafePointer(words.baseAddress!)
        var block = (index % blockCount) * 97 % blockCount
        var sum: UInt64 = 0
        for _ in 0..<blockCount {
            sum &+= Self.hash(base, block: block)
            block += 1
            if block == blockCount { block = 0 }
        }
        return sum == expected
    }
}

// MARK: - Floating point

/// Floating point: a square matrix product in doubles, every step a fused
/// multiply–add, so the result is the same to the bit in any build. A unit
/// multiplies B by A with A's rows turned by the unit's number, which turns
/// the product's rows the same way; its checksum reads the rows back in A's
/// order, so it must match the plain product's.
final class MatrixKernel: BenchmarkKernel, @unchecked Sendable {
    let size: Int
    private let left: UnsafeMutableBufferPointer<Double>
    private let right: UnsafeMutableBufferPointer<Double>
    let expected: UInt64

    init(size: Int, seed: UInt64) {
        self.size = max(size, 1)
        let count = self.size * self.size
        left = .allocate(capacity: count)
        right = .allocate(capacity: count)
        var random = BenchmarkRandom(state: seed)
        for index in 0..<count { left[index] = random.nextSigned() }
        for index in 0..<count { right[index] = random.nextSigned() }
        expected = Self.referenceChecksum(left, right, size: self.size)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// A multiply and an add per step, size³ steps.
    var workPerUnit: Double { 2 * Double(size) * Double(size) * Double(size) }

    func makeWorker(_ index: Int, of count: Int) -> any BenchmarkWorker {
        MatrixWorker(kernel: self)
    }

    /// The product one element at a time, its terms in the same order as a
    /// unit's: each element's sum is the same sequence of fused steps.
    private static func referenceChecksum(_ left: UnsafeMutableBufferPointer<Double>, _ right: UnsafeMutableBufferPointer<Double>,
                                          size: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for row in 0..<size {
            for column in 0..<size {
                var sum = 0.0
                for step in 0..<size { sum = sum.addingProduct(left[row * size + step], right[step * size + column]) }
                checksum = checksum &* 31 &+ sum.bitPattern
            }
        }
        return checksum
    }

    /// One unit into `product`, a size × size scratch matrix.
    func run(unit index: Int, into product: UnsafeMutablePointer<Double>) -> Bool {
        let size = size
        let shift = index % size
        let left = UnsafePointer(left.baseAddress!)
        let right = UnsafePointer(right.baseAddress!)
        for row in 0..<size {
            var source = row + shift
            if source >= size { source -= size }
            let out = product + row * size
            out.update(repeating: 0, count: size)
            for step in 0..<size {
                let factor = left[source * size + step]
                let line = right + step * size
                for column in 0..<size { out[column] = out[column].addingProduct(factor, line[column]) }
            }
        }
        var checksum: UInt64 = 0
        for source in 0..<size {
            var row = source - shift
            if row < 0 { row += size }
            let out = product + row * size
            for column in 0..<size { checksum = checksum &* 31 &+ out[column].bitPattern }
        }
        return checksum == expected
    }
}

/// A worker's own product matrix.
private final class MatrixWorker: BenchmarkWorker, @unchecked Sendable {
    private let kernel: MatrixKernel
    private let product: UnsafeMutablePointer<Double>

    init(kernel: MatrixKernel) {
        self.kernel = kernel
        product = .allocate(capacity: kernel.size * kernel.size)
    }

    deinit { product.deallocate() }

    func run(unit index: Int) -> Bool {
        kernel.run(unit: index, into: product)
    }
}

// MARK: - Memory

/// Memory: adds up the 64-bit words of a buffer far larger than the caches,
/// one chunk per unit. Workers start evenly spread around the buffer and
/// move on a chunk at a time, so they rarely read the same chunk at once.
/// Each chunk's sum is worked out while the buffer is filled.
final class MemoryKernel: BenchmarkKernel, @unchecked Sendable {
    private let words: UnsafeMutableBufferPointer<UInt64>
    let chunkWords: Int
    let chunkCount: Int
    private let expected: [UInt64]

    init(bytes: Int, chunkBytes: Int, seed: UInt64) {
        chunkWords = max(chunkBytes / 8 / 4 * 4, 4)
        chunkCount = max(bytes / 8 / chunkWords, 1)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: chunkCount * chunkWords * 8, alignment: 16_384)
        words = UnsafeMutableBufferPointer(start: raw.bindMemory(to: UInt64.self, capacity: chunkCount * chunkWords),
                                           count: chunkCount * chunkWords)
        var random = BenchmarkRandom(state: seed)
        var sums: [UInt64] = []
        sums.reserveCapacity(chunkCount)
        for chunk in 0..<chunkCount {
            var sum: UInt64 = 0
            for index in chunk * chunkWords..<(chunk + 1) * chunkWords {
                let word = random.next()
                words[index] = word
                sum &+= word
            }
            sums.append(sum)
        }
        expected = sums
    }

    deinit { UnsafeMutableRawPointer(words.baseAddress!).deallocate() }

    var workPerUnit: Double { Double(chunkWords * 8) }

    func makeWorker(_ index: Int, of count: Int) -> any BenchmarkWorker {
        MemoryWorker(kernel: self, start: index * chunkCount / max(count, 1))
    }

    /// Sums one chunk with four running totals, so the adds needn't wait on each other.
    func sum(chunk: Int) -> Bool {
        let base = UnsafePointer(words.baseAddress!) + chunk * chunkWords
        var first: UInt64 = 0, second: UInt64 = 0, third: UInt64 = 0, fourth: UInt64 = 0
        var index = 0
        while index < chunkWords {
            first &+= base[index]
            second &+= base[index + 1]
            third &+= base[index + 2]
            fourth &+= base[index + 3]
            index += 4
        }
        return first &+ second &+ third &+ fourth == expected[chunk]
    }
}

private final class MemoryWorker: BenchmarkWorker, @unchecked Sendable {
    private let kernel: MemoryKernel
    private let start: Int

    init(kernel: MemoryKernel, start: Int) {
        self.kernel = kernel
        self.start = start
    }

    func run(unit index: Int) -> Bool {
        kernel.sum(chunk: (start + index % kernel.chunkCount) % kernel.chunkCount)
    }
}
