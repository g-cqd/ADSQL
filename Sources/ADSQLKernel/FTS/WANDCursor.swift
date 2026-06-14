/// A single FTS term's posting list as a block-max cursor for WAND (F6c). It
/// walks docids in ascending order, gallops (`advance(to:)`) to a target docid by
/// skipping whole posting blocks via their header `lastDocId`, and exposes the
/// admissible per-block score bound (`currentBlockBound`) the pivot test needs.
///
/// Block bodies decode **lazily**: at construction it decodes only the block
/// headers (docCount / firstDocId / lastDocId / maxTotalTF) and records where
/// each block's docid gaps begin, stepping over the per-doc field-TF and position
/// payload (it never needs those — surviving documents are scored by
/// `FTSScorer`, which re-reads the postings). A block's docids are decoded only
/// when the traversal actually enters it, so skipped blocks cost only their
/// header parse. This is the on-disk `FTSPostings` block layout (F2a) read
/// header-first instead of fully materialized.
struct FTSWANDCursor {
  /// The term's posting bytes (the raw tree value).
  private let bytes: [UInt8]
  /// Decoded block headers, ascending by docid range.
  private let blocks: [BlockHeader]
  /// Per-block admissible score bound, parallel to `blocks`.
  private let blockBounds: [Double]
  /// IDF(term) — constant, mirrors `FTSScorer`.
  let idf: Double
  /// Admissible per-term score ceiling across the whole list (max block bound).
  let maxScoreBound: Double
  /// On-disk per-doc payload shape (to decode the current doc's field-TFs).
  private let columns: Int
  private let storePositions: Bool

  /// Current position: which block, that block's decoded docids, and the index
  /// within them.
  private var blockIndex = 0
  private var docids: [Int64] = []
  private var docPos = 0
  /// True once the cursor has advanced past the final docid.
  private(set) var exhausted = false

  struct BlockHeader {
    var docCount: Int
    var firstDocId: Int64
    var lastDocId: Int64
    var maxTotalTF: UInt32
    /// Byte offset of the first docid gap (doc[0] == firstDocId carries no gap).
    var bodyOffset: Int
    /// Byte offset of the per-doc field-TF section (right after the docid gaps).
    var payloadOffset: Int
  }

  /// Builds a cursor over `bytes` (a term's encoded posting list), deriving each
  /// block's admissible bound from the live stats. `columns`/`storePositions`
  /// describe the on-disk per-doc payload so the header walk can step over it.
  /// `maxWeight` is the largest per-column bm25 weight, `avgdl` the corpus average
  /// document length, `dMin` the safe lower bound on document length. Returns nil
  /// for an empty/degenerate list (the caller then treats the term as absent).
  init?(
    bytes: [UInt8], df: UInt64, docCount: UInt64, columns: Int, storePositions: Bool,
    maxWeight: Double, avgdl: Double, dMin: Double
  ) {
    guard !bytes.isEmpty, docCount > 0, avgdl > 0, columns >= 1 else { return nil }
    self.bytes = bytes
    self.columns = columns
    self.storePositions = storePositions
    // IDF mirrors FTSScorer exactly (same clamp of IDF ≤ 0 to `minIDF`).
    self.idf = FTSScorer.idf(df: df, n: Double(docCount))

    var headers: [BlockHeader] = []
    var bounds: [Double] = []
    var offset = 0
    guard let blockCount = Varint.read(bytes, &offset) else { return nil }
    headers.reserveCapacity(Int(blockCount))
    bounds.reserveCapacity(Int(blockCount))
    var ceiling = 0.0
    for _ in 0..<Int(blockCount) {
      guard let rawDocCount = Varint.read(bytes, &offset),
        let firstZig = Varint.read(bytes, &offset),
        let lastZig = Varint.read(bytes, &offset),
        let maxTF = Varint.read(bytes, &offset)
      else { return nil }
      let docCountInBlock = Int(rawDocCount)
      guard docCountInBlock >= 1 else { return nil }
      let bodyOffset = offset
      // Step past the (docCount-1) docid gaps to reach the per-doc field-TF
      // section (recorded so a single doc's TFs can be decoded on demand).
      for _ in 1..<docCountInBlock {
        guard Varint.read(bytes, &offset) != nil else { return nil }
      }
      let header = BlockHeader(
        docCount: docCountInBlock,
        firstDocId: Varint.unzigzag(firstZig),
        lastDocId: Varint.unzigzag(lastZig),
        maxTotalTF: UInt32(truncatingIfNeeded: maxTF),
        bodyOffset: bodyOffset,
        payloadOffset: offset)
      let bound = FTSWAND.blockBound(
        idf: idf, maxTotalTF: header.maxTotalTF, maxWeight: maxWeight, avgdl: avgdl, dMin: dMin)
      headers.append(header)
      bounds.append(bound)
      ceiling = max(ceiling, bound)
      // Step `offset` past the per-doc payload (field-TFs + optional position
      // runs) to the next block header.
      guard
        FTSWANDCursor.skipPayload(
          bytes, &offset, docCount: docCountInBlock, columns: columns,
          storePositions: storePositions)
      else { return nil }
    }
    guard !headers.isEmpty else { return nil }
    self.blocks = headers
    self.blockBounds = bounds
    self.maxScoreBound = ceiling
    decodeBlock(0)
  }

  /// The docid the cursor currently points at, or nil when exhausted.
  var current: Int64? { exhausted ? nil : docids[docPos] }

  /// Admissible score bound for the CURRENT block (≥ the contribution of any doc
  /// the cursor could still yield from this block). nil when exhausted.
  var currentBlockBound: Double? { exhausted ? nil : blockBounds[blockIndex] }

  /// Max docid in the current block (`lastDocId`) — the block-max skip horizon.
  var currentBlockLast: Int64? { exhausted ? nil : blocks[blockIndex].lastDocId }

  /// Decodes the docids of block `index` (lazy; docids only — not field-TFs).
  private mutating func decodeBlock(_ index: Int) {
    let header = blocks[index]
    var ids: [Int64] = [header.firstDocId]
    ids.reserveCapacity(header.docCount)
    var offset = header.bodyOffset
    var previous = header.firstDocId
    for _ in 1..<header.docCount {
      guard let gap = Varint.read(bytes, &offset) else { break }
      previous += Int64(gap)
      ids.append(previous)
    }
    docids = ids
    docPos = 0
    blockIndex = index
  }

  /// Advances to the first docid ≥ `target`, galloping over whole blocks via
  /// `lastDocId` (skipping their bodies) before scanning within the block. After
  /// the call `current` is the first docid ≥ `target`, or nil (exhausted).
  mutating func advance(to target: Int64) {
    if exhausted { return }
    if docids[docPos] >= target { return }
    // Block-max skip: jump to the first block whose lastDocId ≥ target.
    if blocks[blockIndex].lastDocId < target {
      var next = blockIndex + 1
      while next < blocks.count, blocks[next].lastDocId < target { next += 1 }
      if next >= blocks.count { exhausted = true; return }
      decodeBlock(next)
    }
    // Binary search within the (now current) block to the first docid ≥ target.
    var lo = docPos
    var hi = docids.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if docids[mid] < target { lo = mid + 1 } else { hi = mid }
    }
    if lo >= docids.count {
      exhausted = true  // unreachable when lastDocId ≥ target; stay safe.
    } else {
      docPos = lo
    }
  }

  /// Advances strictly past the current docid (forward progress after a document
  /// has been processed).
  mutating func advancePast() {
    guard !exhausted else { return }
    advance(to: docids[docPos] + 1)
  }

  /// The per-column term frequencies of the CURRENT doc, decoded on demand from
  /// its field-TF bytes (the cursor already knows the block's `payloadOffset` and
  /// the doc's index within the block). Returns an all-zero vector when exhausted.
  /// These are the SAME bytes `FTSScorer` reads for this doc, so a score computed
  /// from them is bit-identical. Position runs (when present) are skipped per
  /// preceding doc to reach this doc's field-TFs.
  func currentFieldTFs() -> [UInt32] {
    guard !exhausted else { return [UInt32](repeating: 0, count: columns) }
    let header = blocks[blockIndex]
    var offset = header.payloadOffset
    // Skip the payloads of the `docPos` docs before the current one.
    for _ in 0..<docPos {
      skipOneDocPayload(&offset)
    }
    var tfs = [UInt32](repeating: 0, count: columns)
    for column in 0..<columns {
      guard let tf = Varint.read(bytes, &offset) else { break }
      tfs[column] = UInt32(truncatingIfNeeded: tf)
    }
    return tfs
  }

  /// Steps `offset` past one doc's payload: `columns` field-TF varints, then (if
  /// positions are stored) per-column position runs.
  private func skipOneDocPayload(_ offset: inout Int) {
    for _ in 0..<columns {
      guard Varint.read(bytes, &offset) != nil else { return }
    }
    if storePositions {
      for _ in 0..<columns {
        guard let count = Varint.read(bytes, &offset) else { return }
        for _ in 0..<Int(count) {
          guard Varint.read(bytes, &offset) != nil else { return }
        }
      }
    }
  }

  /// Steps `offset` past a block's per-doc payload — for each doc `columns`
  /// field-TF varints and (if `storePositions`) per-column position runs (a count
  /// varint + that many gap varints) — landing on the next block header. The
  /// preceding docid gaps are stepped over by the caller. Returns false on
  /// truncation. Mirrors `FTSPostings.encode`'s body layout. Paid once per block
  /// at construction, never per query doc.
  static func skipPayload(
    _ bytes: [UInt8], _ offset: inout Int, docCount: Int, columns: Int, storePositions: Bool
  ) -> Bool {
    for _ in 0..<docCount {
      for _ in 0..<columns {
        guard Varint.read(bytes, &offset) != nil else { return false }
      }
      if storePositions {
        for _ in 0..<columns {
          guard let count = Varint.read(bytes, &offset) else { return false }
          for _ in 0..<Int(count) {
            guard Varint.read(bytes, &offset) != nil else { return false }
          }
        }
      }
    }
    return true
  }
}
