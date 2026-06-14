import Testing

@testable import ADSQLKernel

/// F6g — frame-of-reference bit-packed docid gaps. Exhaustive low-level coverage
/// of the `ForPacking` codec (the writer in `FTSPostings.encode`, the readers in
/// `FTSPostings.decode` / `decodeDocids` / `FTSWANDCursor`), independent of the
/// SQLite parity gate: every bit width, byte-straddling field offsets, zero gaps,
/// single-doc blocks, and the 63/64-bit extremes that exercise the cross-byte
/// spill path. A packer/unpacker mismatch silently corrupts retrieval, so this
/// pins the format byte-for-byte.
@Suite("FTS5 — F6g frame-of-reference docid-gap packing")
struct FTSForPackingTests {
    /// Round-trips a raw gap vector through `appendPackedGaps` → `decodeDocids`,
    /// asserting the reconstructed docids equal the prefix-sum of the gaps onto a
    /// chosen `firstDocId`, and that decode consumes exactly the bytes written.
    private func roundTrip(_ gaps: [UInt64], firstDocId: Int64 = 1, line: Int = #line) {
        // docCount = gaps + 1 (doc[0] carries no gap).
        var packed: [UInt8] = []
        ForPacking.appendPackedGaps(gaps, to: &packed)

        var offset = 0
        var docids: [Int64] = []
        let ok = ForPacking.decodeDocids(
            packed, &offset, docCount: gaps.count + 1, firstDocId: firstDocId, into: &docids)
        #expect(ok, "decode failed (line \(line))")
        #expect(offset == packed.count, "decode must consume all bytes (line \(line))")

        var expected: [Int64] = [firstDocId]
        var acc = firstDocId
        for g in gaps {
            acc += Int64(bitPattern: g)
            expected.append(acc)
        }
        #expect(docids == expected, "round-trip mismatch (line \(line))")

        // `skipPackedGaps` must advance to the same offset as a full decode.
        var skipOffset = 0
        let skipped = ForPacking.skipPackedGaps(packed, &skipOffset, gapCount: gaps.count)
        #expect(skipped, "skip failed (line \(line))")
        #expect(skipOffset == packed.count, "skip must match decode offset (line \(line))")
    }

    @Test func emptyAndSingleDocBlocks() {
        // No gaps (single-doc block): writes just `varint gapBits == 0`.
        var packed: [UInt8] = []
        ForPacking.appendPackedGaps([], to: &packed)
        #expect(packed == [0], "empty gap list must be a single 0 byte (gapBits == 0)")
        roundTrip([])
    }

    @Test func allZeroGaps() {
        // Degenerate but valid: every gap zero ⇒ gapBits 0 ⇒ no packed bytes.
        roundTrip([0, 0, 0, 0])
        var packed: [UInt8] = []
        ForPacking.appendPackedGaps([0, 0, 0], to: &packed)
        #expect(packed == [0], "all-zero gaps pack to just the gapBits==0 varint")
    }

    @Test func everyBitWidthSingleField() {
        // A single gap whose value forces each width 1...63; the field is the only one
        // in the block, so it starts byte-aligned. (Width 64 is unreachable for real
        // docid gaps — deltas of ascending Int64 rowids are < 2^63 — but the codec
        // path is still covered by `decodeRawValuesEveryWidth` below.)
        for bits in 1...63 {
            let value: UInt64 = (UInt64(1) << (bits - 1)) | 1
            roundTrip([value], line: bits)
        }
    }

    @Test func everyBitWidthManyFields() {
        // Many fields at each width force byte-straddling offsets (the cross-byte
        // spill in both packer and unpacker). One field carries the width-defining max
        // gap; the rest stay tiny so the prefix-sum of docids stays within Int64 (real
        // docid sequences are monotonic and representable). 17 fields walk the bit
        // offset through every phase 0...7 for most widths.
        for bits in 1...63 {
            let maxValue: UInt64 = (UInt64(1) << (bits - 1)) | 1  // forces exactly `bits`
            let gaps: [UInt64] = (0..<17).map { i in i == 8 ? maxValue : UInt64(i % 3) }
            roundTrip(gaps, firstDocId: 5, line: bits)
        }
    }

    @Test func sixtyThreeBitStraddle() {
        // 63-bit fields at non-zero bit offsets exercise the 9th-byte fold in the
        // decoder (consumed = 64 - bitOffset < 63). One wide field per block forces
        // gapBits == 63; surrounding small fields slide it through the byte phases
        // while keeping the docid sum representable.
        let wide: UInt64 = UInt64(1) << 62  // 63-bit-wide value
        roundTrip([1, wide])  // wide field at offset 1 bit (after a 1-bit... no: gapBits is 63 for the whole block)
        roundTrip([wide, 1])  // wide field first (byte-aligned)
        roundTrip([1, 2, wide, 3, 1])  // wide field after 3×63 bits ⇒ offset 189%8 = 5
    }

    /// The packer/unpacker reproduce the raw `gapBits`-bit VALUES at every width
    /// 1...64 independent of the docid prefix-sum (which would overflow Int64 for
    /// pathological gaps). Decodes with `firstDocId == 0` and reads back the gaps as
    /// successive differences, so the full value range — including the 64-bit and
    /// straddle paths — is verified bit-exactly.
    @Test func decodeRawValuesEveryWidth() {
        for bits in 1...64 {
            let hi: UInt64 = bits == 64 ? (UInt64(1) << 63) : (UInt64(1) << (bits - 1))
            // Values strictly within the width; alternate to exercise carries, kept
            // small enough that the running sum stays < Int64.max (≤ 4 fields).
            let gaps: [UInt64] = [hi | 1, 0, 1, hi >> 1]
            var packed: [UInt8] = []
            ForPacking.appendPackedGaps(gaps, to: &packed)
            var offset = 0
            var docids: [Int64] = []
            let ok = ForPacking.decodeDocids(
                packed, &offset, docCount: gaps.count + 1, firstDocId: 0, into: &docids)
            #expect(ok && offset == packed.count, "width \(bits): decode/consume")
            // Recover gaps as differences and compare to the originals.
            var recovered: [UInt64] = []
            for i in 1..<docids.count {
                recovered.append(UInt64(bitPattern: docids[i] &- docids[i - 1]))
            }
            #expect(recovered == gaps, "width \(bits): raw value round-trip")
        }
    }

    @Test func mixedRealisticGaps() {
        // Ascending docids with small, irregular gaps (the common posting shape).
        let gaps: [UInt64] = [7, 1, 1, 13, 2, 1, 1, 1, 255, 4, 1, 1, 1, 1, 1, 64, 1, 1]
        roundTrip(gaps, firstDocId: 3)
    }

    @Test func truncationIsDetected() {
        // A packed buffer cut short must fail decode (not read out of bounds).
        var packed: [UInt8] = []
        ForPacking.appendPackedGaps([1000, 2000, 3000], to: &packed)
        #expect(packed.count > 1)
        let truncated = Array(packed.dropLast())
        var offset = 0
        var docids: [Int64] = []
        let ok = ForPacking.decodeDocids(
            truncated, &offset, docCount: 4, firstDocId: 1, into: &docids)
        #expect(!ok, "truncated packed gaps must be rejected")
    }

    /// End-to-end through the public `FTSPostings` codec at block boundaries, with
    /// gaps engineered to span several bit widths across blocks (each 128-block gets
    /// its own width). This is the same surface `decode`/`decodeDocids` expose.
    @Test func postingsCodecAcrossBlocksAndWidths() throws {
        // Block 0: tiny gaps (1-bit). Block 1: large gaps (forces a wide width).
        var postings: [FTSPosting] = []
        var docid: Int64 = 1
        for i in 0..<200 {
            postings.append(FTSPosting(docid: docid, fieldTFs: [UInt32(i % 4 + 1)]))
            // First block: gap 1; second block: large, irregular gaps.
            docid += i < 128 ? 1 : Int64(1000 + (i * 37) % 5000)
        }
        let bytes = FTSPostings.encode(postings, columns: 1, storePositions: false)
        let decoded = try FTSPostings.decode(bytes, columns: 1, storePositions: false)
        #expect(decoded == postings)

        // decodeDocids on each single block value (varint(1) || block) must match.
        // Re-encode each block independently the way block-per-key storage stores it.
        let block0 = Array(postings[0..<128])
        let single = FTSPostings.encode(block0, columns: 1, storePositions: false)
        // encode() emits `varint blockCount(==1) || block`, exactly the single-block
        // value `decodeDocids` expects.
        let ids = try FTSPostings.decodeDocids(singleBlock: single)
        #expect(ids == block0.map(\.docid))
    }
}
