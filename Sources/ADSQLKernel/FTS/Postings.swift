/// FTS postings (M5/F2). A term's posting list is the docid-ascending sequence
/// of documents containing it, each carrying per-field term frequencies (for
/// bm25f) and per-field token positions (for phrase queries). The list is stored
/// as fixed-size **blocks** so the ranked retrieval layer (F4) can skip blocks
/// that cannot enter the top-k (block-max WAND, Ding & Suel 2011).
///
/// Each block header carries `lastDocId` (the block's max docid, for galloping /
/// skip) and `maxTotalTF` (the max Σ field-tf in the block — the corpus-stable
/// component of a bm25 impact bound; F4 turns it into a score bound with the
/// live global stats). These are designed in now because the on-disk format is
/// version-gated and F4 cannot add them retroactively.

public struct FTSPosting: Equatable, Sendable {
  public var docid: Int64
  /// Term frequency in each column (length == the FTS table's column count).
  public var fieldTFs: [UInt32]
  /// Token positions in each column (empty when `detail = none`).
  public var positions: [[UInt32]]

  public init(docid: Int64, fieldTFs: [UInt32], positions: [[UInt32]] = []) {
    self.docid = docid
    self.fieldTFs = fieldTFs
    self.positions = positions
  }

  /// Σ of the per-field term frequencies.
  public var totalTF: UInt32 { fieldTFs.reduce(0, +) }
}

public enum FTSPostings {
  /// Postings per block. 128 keeps a block's compressed body small while giving
  /// the skip layer useful granularity (Lucene/PISA-class default).
  public static let blockSize = 128

  /// Block layout, per block:
  ///   varint docCount
  ///   varint zigzag(firstDocId) || varint zigzag(lastDocId) || varint maxTotalTF
  ///   FOR-packed docid gaps (F6g): varint gapBits, then the (docCount-1) gaps as
  ///     fixed-width `gapBits`-bit fields, LSB-first, byte-aligned at the block end
  ///     (gapBits == 0 when docCount == 1). doc[0] == firstDocId carries no gap.
  ///   per doc: `columns` varint field-TFs; then (if positions) per column a
  ///            varint position-count followed by that many varint position gaps
  /// Value layout: varint blockCount || blocks.
  ///
  /// The docid gaps switched from per-value varint to **frame-of-reference**
  /// fixed-bit-width packing (F6g): one bit width per block (the bits its max gap
  /// needs), so decode is a branchless bulk-unpack + prefix-sum — no per-value
  /// continuation-bit branching. Byte-alignment at the block end keeps the next
  /// block's header on a byte boundary. The per-doc TF/position payload stays
  /// varint (variance there is high; FOR buys little).
  public static func encode(
    _ postings: [FTSPosting], columns: Int, storePositions: Bool
  ) -> [UInt8] {
    var out: [UInt8] = []
    let blockCount = (postings.count + blockSize - 1) / blockSize
    Varint.append(UInt64(blockCount), to: &out)

    var index = 0
    while index < postings.count {
      let end = min(index + blockSize, postings.count)
      let block = postings[index..<end]
      let firstDocId = block.first!.docid
      let lastDocId = block.last!.docid
      var maxTotalTF: UInt32 = 0
      for posting in block { maxTotalTF = max(maxTotalTF, posting.totalTF) }

      Varint.append(UInt64(end - index), to: &out)
      Varint.append(Varint.zigzag(firstDocId), to: &out)
      Varint.append(Varint.zigzag(lastDocId), to: &out)
      Varint.append(UInt64(maxTotalTF), to: &out)

      var gaps: [UInt64] = []
      gaps.reserveCapacity(block.count - 1)
      var previous = firstDocId
      for posting in block.dropFirst() {
        gaps.append(UInt64(posting.docid - previous))
        previous = posting.docid
      }
      ForPacking.appendPackedGaps(gaps, to: &out)
      for posting in block {
        for column in 0..<columns {
          Varint.append(UInt64(column < posting.fieldTFs.count ? posting.fieldTFs[column] : 0), to: &out)
        }
        if storePositions {
          for column in 0..<columns {
            let positions = column < posting.positions.count ? posting.positions[column] : []
            Varint.append(UInt64(positions.count), to: &out)
            var previousPosition: UInt32 = 0
            for position in positions {
              Varint.append(UInt64(position - previousPosition), to: &out)
              previousPosition = position
            }
          }
        }
      }
      index = end
    }
    return out
  }

  public static func decode(
    _ bytes: [UInt8], columns: Int, storePositions: Bool
  ) throws(DBError) -> [FTSPosting] {
    var offset = 0
    guard let blockCount = Varint.read(bytes, &offset) else {
      throw DBError.integrityFailure("fts postings: missing block count")
    }
    var result: [FTSPosting] = []
    for _ in 0..<Int(blockCount) {
      guard let rawDocCount = Varint.read(bytes, &offset),
        let firstZigzag = Varint.read(bytes, &offset),
        Varint.read(bytes, &offset) != nil,  // lastDocId — skip metadata (F3/F4)
        Varint.read(bytes, &offset) != nil  // maxTotalTF — block-max bound (F4)
      else { throw DBError.integrityFailure("fts postings: truncated block header") }
      let docCount = Int(rawDocCount)
      guard docCount >= 1 else { throw DBError.integrityFailure("fts postings: empty block") }

      var docids: [Int64] = []
      docids.reserveCapacity(docCount)
      guard
        ForPacking.decodeDocids(
          bytes, &offset, docCount: docCount, firstDocId: Varint.unzigzag(firstZigzag),
          into: &docids)
      else { throw DBError.integrityFailure("fts postings: truncated docid gaps") }

      for docIndex in 0..<docCount {
        var fieldTFs: [UInt32] = []
        fieldTFs.reserveCapacity(columns)
        for _ in 0..<columns {
          guard let tf = Varint.read(bytes, &offset) else {
            throw DBError.integrityFailure("fts postings: truncated field tf")
          }
          fieldTFs.append(UInt32(truncatingIfNeeded: tf))
        }
        var positions: [[UInt32]] = []
        if storePositions {
          positions.reserveCapacity(columns)
          for _ in 0..<columns {
            guard let count = Varint.read(bytes, &offset) else {
              throw DBError.integrityFailure("fts postings: truncated position count")
            }
            var column: [UInt32] = []
            var previousPosition: UInt32 = 0
            for _ in 0..<Int(count) {
              guard let gap = Varint.read(bytes, &offset) else {
                throw DBError.integrityFailure("fts postings: truncated position")
              }
              previousPosition += UInt32(truncatingIfNeeded: gap)
              column.append(previousPosition)
            }
            positions.append(column)
          }
        }
        result.append(
          FTSPosting(docid: docids[docIndex], fieldTFs: fieldTFs, positions: positions))
      }
    }
    return result
  }

  /// Docids only, from a SINGLE-block value (F6d block-per-key storage): reads the
  /// block header + docid gaps and STOPS, skipping the per-doc field-TF/position
  /// payload entirely. For membership (`MATCH`) where only docids are needed — the
  /// skipped payload is the bulk of a long list's bytes (F6e).
  public static func decodeDocids(singleBlock bytes: [UInt8]) throws(DBError) -> [Int64] {
    var offset = 0
    guard Varint.read(bytes, &offset) == 1 else {
      throw DBError.integrityFailure("fts postings: decodeDocids expects a single-block value")
    }
    guard let rawDocCount = Varint.read(bytes, &offset),
      let firstZigzag = Varint.read(bytes, &offset),
      Varint.read(bytes, &offset) != nil,  // lastDocId
      Varint.read(bytes, &offset) != nil  // maxTotalTF
    else { throw DBError.integrityFailure("fts postings: truncated block header") }
    let docCount = Int(rawDocCount)
    guard docCount >= 1 else { throw DBError.integrityFailure("fts postings: empty block") }
    var docids: [Int64] = []
    docids.reserveCapacity(docCount)
    guard
      ForPacking.decodeDocids(
        bytes, &offset, docCount: docCount, firstDocId: Varint.unzigzag(firstZigzag),
        into: &docids)
    else { throw DBError.integrityFailure("fts postings: truncated docid gaps") }
    return docids
  }
}

/// Frame-of-reference fixed-bit-width packing for a posting block's docid gaps
/// (F6g). One bit width per block — the bits its single largest gap needs — then
/// the `(docCount-1)` gaps as that-many-bit fields, LSB-first in a little-endian
/// bit stream, padded to a byte boundary at the block end (so the next block's
/// varint header stays byte-aligned). Decode is branchless: a fixed-width field
/// extractor (no per-value continuation-bit branch, unlike varint) feeding a
/// serial prefix-sum that rebuilds ascending docids.
///
/// Why scalar (not `simd`): `gapBits` is runtime-variable per block (1...64) and
/// the prefix-sum is inherently serial (each docid depends on the running total).
/// SIMD bit-unpacking pays off only at a fixed lane width packed in fixed-size
/// groups (SIMD-BP128/PFor); here the variable width + serial carry make a tight
/// branchless scalar reader the clean win. The packing stays on bounds-checked
/// `[UInt8]` (matching the codec's existing safe `Varint.read([UInt8])` path), so
/// no `unsafe` is needed under strict-memory-safety.
enum ForPacking {
  /// Appends `varint gapBits || packed gaps` (byte-aligned). `gapBits == 0` for an
  /// empty gap list (single-doc block), which writes just the `0` varint.
  /// Fields are written LSB-first at successive bit positions via byte-granular
  /// read-modify-write; the final byte is zero-padded to the boundary. This mirror
  /// of the decoder's bit-addressing is correct for any `gapBits ∈ [1, 64]` (no
  /// staging-word overflow regardless of width or straddle).
  static func appendPackedGaps(_ gaps: [UInt64], to out: inout [UInt8]) {
    var maxGap: UInt64 = 0
    for gap in gaps { maxGap = max(maxGap, gap) }
    let gapBits = maxGap == 0 ? 0 : 64 - maxGap.leadingZeroBitCount
    Varint.append(UInt64(gapBits), to: &out)
    guard gapBits > 0, !gaps.isEmpty else { return }

    let mask: UInt64 = gapBits == 64 ? ~0 : (UInt64(1) << gapBits) - 1
    let byteCount = (gaps.count * gapBits + 7) / 8
    let base = out.count
    out.append(contentsOf: repeatElement(0, count: byteCount))
    var bitPos = 0
    for gap in gaps {
      var value = gap & mask
      var bitOffset = bitPos & 7
      var byteIndex = base + (bitPos >> 3)
      // Deposit `gapBits` bits LSB-first, spilling across byte boundaries.
      var remaining = gapBits
      while remaining > 0 {
        let room = 8 - bitOffset
        out[byteIndex] |= UInt8(truncatingIfNeeded: value << bitOffset)
        let written = min(room, remaining)
        value >>= written
        remaining -= written
        bitOffset = 0
        byteIndex += 1
      }
      bitPos += gapBits
    }
  }

  /// Reads `varint gapBits` then the `(docCount-1)` packed gaps and prefix-sums
  /// them onto `firstDocId`, appending all `docCount` docids to `into`. Advances
  /// `offset` past the byte-aligned packed region. Returns false on truncation.
  static func decodeDocids(
    _ bytes: [UInt8], _ offset: inout Int, docCount: Int, firstDocId: Int64,
    into docids: inout [Int64]
  ) -> Bool {
    guard let rawGapBits = Varint.read(bytes, &offset) else { return false }
    let gapBits = Int(rawGapBits)
    guard gapBits <= 64 else { return false }

    var docid = firstDocId
    docids.append(docid)
    let gapCount = docCount - 1
    guard gapCount > 0 else { return true }
    guard gapBits > 0 else {
      // All gaps are zero (duplicate docids in-block — degenerate but valid).
      for _ in 0..<gapCount { docids.append(docid) }
      return true
    }

    let totalBits = gapCount * gapBits
    let byteCount = (totalBits + 7) / 8
    guard offset + byteCount <= bytes.count else { return false }
    let base = offset
    let mask: UInt64 = gapBits == 64 ? ~0 : (UInt64(1) << gapBits) - 1

    var bitPos = 0
    for _ in 0..<gapCount {
      // Extract `gapBits` LSB-first from the byte stream starting at `base`. Load
      // up to 8 bytes spanning the field (branchless within the field) and shift.
      let byteIndex = base + (bitPos >> 3)
      let bitOffset = bitPos & 7
      var window: UInt64 = 0
      // A `gapBits`-bit field at `bitOffset` spans at most ceil((64+7)/8)=9 bytes
      // when gapBits==64 and bitOffset>0; load 8 then patch the 9th below.
      var shift = 0
      var b = byteIndex
      while shift < 64, b < bytes.count {
        window |= UInt64(bytes[b]) << shift
        shift += 8
        b += 1
      }
      var value = (window >> bitOffset) & mask
      // When the field straddles past the 8 bytes loaded (only possible for
      // gapBits + bitOffset > 64, i.e. very large gapBits), fold in the 9th byte.
      let consumed = 64 - bitOffset
      if gapBits > consumed, b < bytes.count {
        value |= (UInt64(bytes[b]) << consumed) & mask
      }
      docid += Int64(bitPattern: value)
      docids.append(docid)
      bitPos += gapBits
    }
    offset = base + byteCount
    return true
  }

  /// Steps `offset` past a byte-aligned FOR gaps region without decoding it (used
  /// by the WAND cursor's header walk). Reads `gapBits`, computes the packed byte
  /// count for `gapCount` fields, and skips it. Returns false on truncation.
  static func skipPackedGaps(
    _ bytes: [UInt8], _ offset: inout Int, gapCount: Int
  ) -> Bool {
    guard let rawGapBits = Varint.read(bytes, &offset) else { return false }
    let gapBits = Int(rawGapBits)
    guard gapBits <= 64 else { return false }
    guard gapCount > 0, gapBits > 0 else { return true }
    let byteCount = (gapCount * gapBits + 7) / 8
    guard offset + byteCount <= bytes.count else { return false }
    offset += byteCount
    return true
  }
}
