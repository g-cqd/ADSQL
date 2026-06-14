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
  ///   (docCount-1) varint docid gaps (ascending; doc[0] = firstDocId)
  ///   per doc: `columns` varint field-TFs; then (if positions) per column a
  ///            varint position-count followed by that many varint position gaps
  /// Value layout: varint blockCount || blocks.
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

      var previous = firstDocId
      for posting in block.dropFirst() {
        Varint.append(UInt64(posting.docid - previous), to: &out)
        previous = posting.docid
      }
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

      var docids: [Int64] = [Varint.unzigzag(firstZigzag)]
      docids.reserveCapacity(docCount)
      for _ in 1..<docCount {
        guard let gap = Varint.read(bytes, &offset) else {
          throw DBError.integrityFailure("fts postings: truncated docid gap")
        }
        docids.append(docids[docids.count - 1] + Int64(gap))
      }

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
    var docid = Varint.unzigzag(firstZigzag)
    docids.append(docid)
    for _ in 1..<docCount {
      guard let gap = Varint.read(bytes, &offset) else {
        throw DBError.integrityFailure("fts postings: truncated docid gap")
      }
      docid += Int64(gap)
      docids.append(docid)
    }
    return docids
  }
}
