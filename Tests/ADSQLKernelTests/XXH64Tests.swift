import Testing

@testable import ADSQLKernel

@Suite("XXH64")
struct XXH64Tests {
    // Reference values cross-checked against Bun.hash.xxHash64 (xxhash C impl).
    static let vectors: [(input: [UInt8], seed: UInt64, expected: UInt64)] = [
        ([], 0, 0xEF46_DB37_51D8_E999),
        ([], 1, 0xD5AF_BA13_36A3_BE4B),
        (Array("a".utf8), 0, 0xD24E_C4F1_A98C_6E5B),
        (Array("abc".utf8), 0, 0x44BC_2CF5_AD77_0999),
        (Array("ADSQLv0".utf8), 0, 0x3561_29A6_B6B0_2961),
        (Array("The quick brown fox jumps over the lazy dog".utf8), 0, 0x0B24_2D36_1FDA_71BC),
        (Array("The quick brown fox jumps over the lazy dog".utf8), 0xDEAD_BEEF, 0x1F0B_04B3_0B66_5910),
    ]

    @Test(arguments: vectors.indices)
    func referenceVectors(_ i: Int) {
        let v = Self.vectors[i]
        #expect(XXH64.hash(v.input, seed: v.seed) == v.expected)
    }

    /// Deterministic 16 KiB page-shaped buffer: byte i = (i * 31 + 7) & 0xFF.
    static func patternBuffer(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }
    }

    @Test func pageSizedBuffer() {
        #expect(XXH64.hash(Self.patternBuffer(16384), seed: 42) == 0xA102_F3DF_F427_C676)
    }

    @Test func metaSizedBuffer() {
        #expect(XXH64.hash(Self.patternBuffer(120), seed: 0) == 0x389E_4F4E_7164_8711)
    }

    @Test func tailHandling33Bytes() {
        #expect(XXH64.hash(Self.patternBuffer(33), seed: 7) == 0x338D_ACB2_402D_BBBF)
    }

    @Test func seedSensitivity() {
        let buf = Self.patternBuffer(512)
        #expect(XXH64.hash(buf, seed: 1) != XXH64.hash(buf, seed: 2))
    }

    @Test func singleBitAvalanche() {
        var buf = Self.patternBuffer(16384)
        let base = XXH64.hash(buf, seed: 9)
        buf[8191] ^= 0x01
        let flipped = XXH64.hash(buf, seed: 9)
        #expect(base != flipped)
        // Cheap avalanche sanity: a healthy 64-bit hash flips ~32 bits.
        let hamming = (base ^ flipped).nonzeroBitCount
        #expect(hamming > 10)
    }
}
