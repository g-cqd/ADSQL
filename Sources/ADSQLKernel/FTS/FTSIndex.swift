/// FTS index build + maintenance (M5/F2b, F6d). Drives a tokenized document into
/// the three per-FTS-table B+trees the catalog `FTSRecord` owns:
///
///   - **dict**: `term → varint df` (df == posting-list length). Gives F3
///     prefix-term enumeration + IDF without decoding postings.
///   - **postings**: a term's block-compressed posting list (F2a `FTSPostings`),
///     stored **one fixed-size block per key** (F6d): key `varint(len)||term||
///     bigEndian(blockNo)`, value a single-block `FTSPostings` payload (≤128
///     docs). Appending a document rewrites only the last block (O(blockSize))
///     instead of the whole list (O(list)), turning a bulk build from O(n²) into
///     O(n). Blocks stay packed (all full but the last), so `blockNo = (df-1)/128`
///     and a term's blocks are `0...lastNo` — no separate segment directory.
///   - **stats**: `rowKey(docid) → forward record` (field lengths + the doc's
///     distinct terms — the delete companion) and `[0x00] → global aggregates`.
///
/// Readers reconstitute a term's whole list by unioning its block-keys
/// (`postingsValue`), so `postings`/MATCH/WAND/the scorer are unchanged.
enum FTSIndex {
  /// Tokens longer than this are skipped (kept out of the term keyspace); they
  /// still count toward field length. B+tree keys are bounded by `maxKeySize`.
  static let maxTermBytes = 256
  /// Global-aggregates key. One byte sorts before every 8-byte `rowKey`, so a
  /// `move(to: .last)` on the stats tree lands on the largest docid.
  static let globalKey: [UInt8] = [0x00]

  // MARK: - Build

  /// One document buffered in the transaction-scoped FTS memtable (F6f). `ftsAdd`
  /// appends these; the flush (`addBatch`) writes them coalesced.
  struct PendingDoc: Sendable {
    let docid: Int64
    let columnTexts: [String]
  }

  /// Indexes a BATCH of documents in one coalesced pass (the F6f memtable flush).
  /// Tokenizes every doc, accumulates `term → [posting]` across the whole batch,
  /// then merges each term's postings into the tree ONCE — O(distinct terms)
  /// block writes instead of O(docs × terms/doc), the build-throughput win.
  /// `docs` need not be docid-sorted; a docid already on disk or repeated within
  /// the batch is rejected (mirrors the per-doc invariant) — but the error now
  /// surfaces at flush (the next same-table read or commit) and so aborts the
  /// whole transaction rather than the individual INSERT statement.
  static func addBatch(
    _ ctx: TxnContext, record: inout Catalog.FTSRecord, docs: [PendingDoc]
  ) throws(DBError) {
    guard !docs.isEmpty else { return }
    let columns = record.definition.columns.count
    let storePositions = record.definition.detail != .none
    let tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)

    var stats = record.stats
    var termPostings: [[UInt8]: [FTSPosting]] = [:]
    var forwards: [(docid: Int64, fieldLengths: [UInt32], terms: [[UInt8]])] = []
    var seen = Set<Int64>()
    for doc in docs {
      guard seen.insert(doc.docid).inserted,
        try Relation.getBytes(ctx, stats, key: KeyCodec.rowKey(doc.docid)) == nil
      else {
        throw DBError.invalidDefinition(
          "fts \(record.definition.name): docid \(doc.docid) already indexed")
      }
      var fieldLengths = [UInt32](repeating: 0, count: columns)
      var termInfo: [[UInt8]: (fieldTFs: [UInt32], positions: [[UInt32]])] = [:]
      for column in 0..<min(columns, doc.columnTexts.count) {
        try tokenizer.tokenize(Array(doc.columnTexts[column].utf8)) { (token) throws(DBError) in
          fieldLengths[column] += 1
          guard !token.term.isEmpty, token.term.count <= maxTermBytes else { return }
          if termInfo[token.term] == nil {
            termInfo[token.term] = (
              fieldTFs: [UInt32](repeating: 0, count: columns),
              positions: Array(repeating: [UInt32](), count: columns))
          }
          termInfo[token.term]!.fieldTFs[column] += 1
          if storePositions { termInfo[token.term]!.positions[column].append(UInt32(token.position)) }
        }
      }
      for (term, info) in termInfo {
        termPostings[term, default: []].append(
          FTSPosting(
            docid: doc.docid, fieldTFs: info.fieldTFs,
            positions: storePositions ? info.positions : []))
      }
      forwards.append((doc.docid, fieldLengths, Array(termInfo.keys)))
    }

    var dict = record.dict
    var postings = record.postings
    for (term, additions) in termPostings {
      let sorted = additions.sorted { $0.docid < $1.docid }
      let oldDF = try documentFrequency(ctx, dict, term: term)
      let finalCount: Int
      if oldDF == 0 {
        try writePacked(ctx, &postings, term: term, sorted, columns: columns, positions: storePositions)
        finalCount = sorted.count
      } else {
        let lastNo = blockNo(forDF: oldDF)
        let lastBlock = try readBlock(
          ctx, postings, term: term, blockNo: lastNo, columns: columns, positions: storePositions)
        if let lastDocid = lastBlock.last?.docid, let firstNew = sorted.first?.docid,
          firstNew > lastDocid {
          // Ascending append (the bulk-build common case): re-pack only the last
          // block plus the appended postings into blocks from `lastNo` — O(batch),
          // never re-reading earlier blocks, so a multi-batch build stays linear.
          let combined = lastBlock + sorted
          var no = lastNo
          var start = 0
          while start < combined.count {
            let end = min(start + FTSPostings.blockSize, combined.count)
            try writeBlock(
              ctx, &postings, term: term, blockNo: no, Array(combined[start..<end]),
              columns: columns, positions: storePositions)
            no += 1
            start = end
          }
          finalCount = Int(oldDF) + sorted.count
        } else {
          // Out-of-order: read the whole list, merge, re-pack.
          let merged = mergePostings(
            try fullList(ctx, postings, term: term, columns: columns, positions: storePositions),
            sorted)
          try rewritePacked(
            ctx, &postings, term: term, oldLastNo: lastNo, merged, columns: columns,
            positions: storePositions)
          finalCount = merged.count
        }
      }
      try Relation.putBytes(ctx, &dict, key: term, value: encodeDF(UInt64(finalCount)))
    }

    var global = try readGlobal(ctx, stats, columns: columns)
    for fwd in forwards {
      try Relation.putBytes(
        ctx, &stats, key: KeyCodec.rowKey(fwd.docid),
        value: encodeForward(fieldLengths: fwd.fieldLengths, terms: fwd.terms))
      global.docCount += 1
      for column in 0..<min(columns, fwd.fieldLengths.count) {
        global.totalFieldLengths[column] += UInt64(fwd.fieldLengths[column])
      }
    }
    try Relation.putBytes(ctx, &stats, key: globalKey, value: global.encode())

    record.dict = dict
    record.postings = postings
    record.stats = stats
  }

  /// Merges two docid-ascending posting lists into one (stable on equal docids,
  /// which the batch's dup-check rules out anyway).
  private static func mergePostings(_ a: [FTSPosting], _ b: [FTSPosting]) -> [FTSPosting] {
    if a.isEmpty { return b }
    if b.isEmpty { return a }
    var out: [FTSPosting] = []
    out.reserveCapacity(a.count + b.count)
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if a[i].docid <= b[j].docid {
        out.append(a[i])
        i += 1
      } else {
        out.append(b[j])
        j += 1
      }
    }
    if i < a.count { out.append(contentsOf: a[i...]) }
    if j < b.count { out.append(contentsOf: b[j...]) }
    return out
  }

  @discardableResult
  static func remove(
    _ ctx: TxnContext, record: inout Catalog.FTSRecord, docid: Int64
  ) throws(DBError) -> Bool {
    let columns = record.definition.columns.count
    let storePositions = record.definition.detail != .none
    let docKey = KeyCodec.rowKey(docid)
    guard let forwardBytes = try Relation.getBytes(ctx, record.stats, key: docKey) else {
      return false
    }
    let forward = try decodeForward(forwardBytes)

    var dict = record.dict
    var postings = record.postings
    var stats = record.stats
    for term in forward.terms {
      let oldDF = try documentFrequency(ctx, dict, term: term)
      guard oldDF > 0 else { continue }
      let lastNo = blockNo(forDF: oldDF)
      var list = try fullList(
        ctx, postings, term: term, columns: columns, positions: storePositions)
      list.removeAll { $0.docid == docid }
      // Drop the term's existing blocks, then re-pack what remains.
      for no in 0...lastNo { _ = try Relation.deleteBytes(ctx, &postings, key: blockKey(term, no)) }
      if list.isEmpty {
        _ = try Relation.deleteBytes(ctx, &dict, key: term)
      } else {
        try writePacked(
          ctx, &postings, term: term, list, columns: columns, positions: storePositions)
        try Relation.putBytes(ctx, &dict, key: term, value: encodeDF(UInt64(list.count)))
      }
    }
    _ = try Relation.deleteBytes(ctx, &stats, key: docKey)
    var global = try readGlobal(ctx, stats, columns: columns)
    if global.docCount > 0 { global.docCount -= 1 }
    for column in 0..<min(columns, forward.fieldLengths.count) {
      let length = UInt64(forward.fieldLengths[column])
      global.totalFieldLengths[column] =
        global.totalFieldLengths[column] >= length ? global.totalFieldLengths[column] - length : 0
    }
    try Relation.putBytes(ctx, &stats, key: globalKey, value: global.encode())

    record.dict = dict
    record.postings = postings
    record.stats = stats
    return true
  }

  /// Clears the whole index (`'delete-all'`): frees the three trees and resets
  /// the record's handles to empty. Global/per-doc stats vanish with the trees.
  static func removeAll(_ ctx: TxnContext, record: inout Catalog.FTSRecord) throws(DBError) {
    try Relation.freeTree(ctx, handle: record.dict)
    try Relation.freeTree(ctx, handle: record.postings)
    try Relation.freeTree(ctx, handle: record.stats)
    record.dict = .empty
    record.postings = .empty
    record.stats = .empty
  }

  /// Next auto docid: max docid in the stats tree + 1 (1 when empty). The global
  /// `[0x00]` row sorts first, so the last key — when present — is a doc key.
  static func nextRowid(_ resolver: some PageResolver, statsHandle: TreeHandle) throws(DBError) -> Int64 {
    var cursor = Cursor(resolver: resolver, tree: statsHandle)
    var next: Int64 = 1
    if try cursor.move(to: .last) {
      let last: Int64?? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
        unsafe KeyCodec.rowid(fromSuffixOf: key)
      }
      if let maxDocid = last ?? nil, maxDocid >= 0, maxDocid < Int64.max { next = maxDocid + 1 }
    }
    return next
  }

  // MARK: - Reads (tests + F3/F4)

  static func postings(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> [FTSPosting]? {
    guard let value = try postingsValue(resolver, record, term: term) else { return nil }
    return try FTSPostings.decode(
      value, columns: record.definition.columns.count,
      storePositions: record.definition.detail != .none)
  }

  /// A term's whole posting list reconstituted as a single multi-block
  /// `FTSPostings` value, unioning its `0...lastNo` block-keys. nil when the term
  /// is absent. Readers (`postings`, MATCH, WAND, the scorer) consume this so
  /// they are oblivious to the block-per-key storage.
  static func postingsValue(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> [UInt8]? {
    // One range scan over the term's block-keys, reassembled into the single
    // multi-block value. Each block value is `varint(1) || block`; the per-block
    // count prefix is dropped and the running total re-emitted at the head.
    var bodies: [[UInt8]] = []
    try forEachBlockValue(resolver, record.postings, term: term) { value in
      bodies.append(Array(value.dropFirst()))
    }
    guard !bodies.isEmpty else { return nil }
    var combined: [UInt8] = []
    Varint.append(UInt64(bodies.count), to: &combined)
    for body in bodies { combined.append(contentsOf: body) }
    return combined
  }

  /// Docids only for `term` — unions the term's block-keys, decoding just docids
  /// from each block and skipping its TF/position payload (F6e membership fast
  /// path). nil when the term is absent.
  static func docids(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> [Int64]? {
    var ids: [Int64] = []
    var present = false
    try forEachBlockValue(resolver, record.postings, term: term) { (value) throws(DBError) in
      present = true
      ids.append(contentsOf: try FTSPostings.decodeDocids(singleBlock: value))
    }
    return present ? ids : nil
  }

  static func documentFrequency(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> UInt64 {
    try documentFrequency(resolver, record.dict, term: term)
  }

  static func globalStats(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord
  ) throws(DBError) -> FTSGlobalStats {
    try readGlobal(resolver, record.stats, columns: record.definition.columns.count)
  }

  static func docStats(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, docid: Int64
  ) throws(DBError) -> FTSDocStats? {
    guard let bytes = try Relation.getBytes(resolver, record.stats, key: KeyCodec.rowKey(docid)) else {
      return nil
    }
    return FTSDocStats(fieldLengths: try decodeForward(bytes).fieldLengths)
  }

  /// The document's total length `D = Σ_c fieldLengths` — the only forward-record
  /// datum bm25 scoring needs — read ZERO-COPY and decoding ONLY the leading
  /// field-length varints. It never copies the record nor decodes the doc's term
  /// list (the bulk of the record, and a `[[UInt8]]` the scorer would discard), so
  /// the per-scored-document length read costs a tree descent plus a few varints.
  /// nil when the doc has no stats row (an absent/removed doc), mirroring
  /// `docStats`. Hot path: one call per scored document.
  static func docLength(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, docid: Int64
  ) throws(DBError) -> Double? {
    try Relation.withRowValue(resolver, record.stats, key: KeyCodec.rowKey(docid)) {
      (ref) throws(DBError) in
      try unsafe BTree.withValueBytes(ref, resolver: resolver) { (raw) throws(DBError) -> Double in
        var offset = 0
        guard let fieldCount = unsafe Varint.read(raw, &offset) else {
          throw DBError.integrityFailure("fts forward: missing field count")
        }
        var total = 0.0
        for _ in 0..<fieldCount {
          guard let length = unsafe Varint.read(raw, &offset) else {
            throw DBError.integrityFailure("fts forward: truncated field length")
          }
          total += Double(length)
        }
        return total
      }
    }
  }

  /// Every dictionary term that starts with `prefix` (for `foo*` queries). The
  /// dict tree is keyed by raw term bytes, so a seek + ascending walk while the
  /// key still carries the prefix enumerates the range.
  static func termsMatchingPrefix(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, prefix: [UInt8]
  ) throws(DBError) -> [[UInt8]] {
    var terms: [[UInt8]] = []
    var cursor = Cursor(resolver: resolver, tree: record.dict)
    var positioned = false
    var failure: DBError?
    prefix.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        positioned = cursor.isValid
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    while positioned {
      let proceed: Bool? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
        let term = unsafe [UInt8](key)
        guard term.starts(with: prefix) else { return false }
        terms.append(term)
        return true
      }
      guard proceed == true else { break }
      positioned = try cursor.next()
    }
    return terms
  }

  // MARK: - Block-per-key storage (F6d)

  /// The packed-block invariant means a term's blocks are `0...(df-1)/128`.
  @inline(__always)
  private static func blockNo(forDF df: UInt64) -> UInt32 {
    UInt32((df - 1) / UInt64(FTSPostings.blockSize))
  }

  /// Postings key: `varint(termLen) || term || bigEndian(blockNo)`. The length
  /// prefix keeps one term's keys from colliding with another's (no term is a
  /// key-prefix of another), and the 4-byte big-endian `blockNo` sorts blocks
  /// ascending == docid-ascending.
  private static func blockKey(_ term: [UInt8], _ no: UInt32) -> [UInt8] {
    var key = blockKeyPrefix(term)
    key.append(UInt8(truncatingIfNeeded: no >> 24))
    key.append(UInt8(truncatingIfNeeded: no >> 16))
    key.append(UInt8(truncatingIfNeeded: no >> 8))
    key.append(UInt8(truncatingIfNeeded: no))
    return key
  }

  /// The shared key prefix of a term's block-keys: `varint(len) || term`. A block
  /// adds a 4-byte big-endian `blockNo`; the length prefix means no term's prefix
  /// is a prefix of another's, so a range scan over this enumerates exactly one
  /// term's blocks.
  private static func blockKeyPrefix(_ term: [UInt8]) -> [UInt8] {
    var key: [UInt8] = []
    key.reserveCapacity(term.count + 2)
    Varint.append(UInt64(term.count), to: &key)
    key.append(contentsOf: term)
    return key
  }

  /// Visits a term's block values in `blockNo` order via ONE cursor range scan
  /// (seek the prefix, walk while it holds) — far cheaper than a point-get per
  /// block on a multi-block term (one tree descent + leaf walk vs one descent
  /// each). Used by every read path.
  private static func forEachBlockValue(
    _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8],
    _ body: ([UInt8]) throws(DBError) -> Void
  ) throws(DBError) {
    let prefix = blockKeyPrefix(term)
    var cursor = Cursor(resolver: resolver, tree: handle)
    var positioned = false
    var failure: DBError?
    prefix.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        positioned = cursor.isValid
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    while positioned {
      // One cursor access per block: prefix-check the raw key in place (no key
      // copy) and materialize the value only if it still belongs to this term.
      // nil ⇒ key left the term's range (or the cursor went invalid) ⇒ stop.
      let value: [UInt8]? =
        unsafe try cursor.withCurrent { (key, ref) throws(DBError) -> [UInt8]? in
          guard unsafe rawHasPrefix(key, prefix) else { return nil }
          return try BTree.copyValue(ref, resolver: resolver)
        } ?? nil
      guard let value else { break }
      try body(value)
      positioned = try cursor.next()
    }
  }

  /// Whether the raw cursor key begins with `prefix`, compared in place against the
  /// mapped page bytes (no `[UInt8]` materialization — the per-block key copy was
  /// pure overhead, the key is only tested, never kept).
  @inline(__always)
  private static func rawHasPrefix(_ key: UnsafeRawBufferPointer, _ prefix: [UInt8]) -> Bool {
    guard key.count >= prefix.count else { return false }
    for index in 0..<prefix.count where unsafe key[index] != prefix[index] { return false }
    return true
  }

  private static func writeBlock(
    _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], blockNo no: UInt32,
    _ block: [FTSPosting], columns: Int, positions: Bool
  ) throws(DBError) {
    try Relation.putBytes(
      ctx, &handle, key: blockKey(term, no),
      value: FTSPostings.encode(block, columns: columns, storePositions: positions))
  }

  private static func readBlock(
    _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8], blockNo no: UInt32,
    columns: Int, positions: Bool
  ) throws(DBError) -> [FTSPosting] {
    guard let value = try Relation.getBytes(resolver, handle, key: blockKey(term, no)) else {
      return []
    }
    return try FTSPostings.decode(value, columns: columns, storePositions: positions)
  }

  /// Decodes a term's whole list via a range scan over its block-keys.
  private static func fullList(
    _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8],
    columns: Int, positions: Bool
  ) throws(DBError) -> [FTSPosting] {
    var list: [FTSPosting] = []
    try forEachBlockValue(resolver, handle, term: term) { (value) throws(DBError) in
      list.append(
        contentsOf: try FTSPostings.decode(value, columns: columns, storePositions: positions))
    }
    return list
  }

  /// Writes `list` (docid-ascending) as packed blocks `0...`.
  private static func writePacked(
    _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], _ list: [FTSPosting],
    columns: Int, positions: Bool
  ) throws(DBError) {
    var no: UInt32 = 0
    var start = 0
    while start < list.count {
      let end = min(start + FTSPostings.blockSize, list.count)
      try writeBlock(
        ctx, &handle, term: term, blockNo: no, Array(list[start..<end]), columns: columns,
        positions: positions)
      no += 1
      start = end
    }
  }

  /// Re-packs a term after an out-of-order insert: drops the old `0...oldLastNo`
  /// blocks, then writes the merged list packed. (`list` is non-empty here.)
  private static func rewritePacked(
    _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], oldLastNo: UInt32,
    _ list: [FTSPosting], columns: Int, positions: Bool
  ) throws(DBError) {
    let newLastNo = blockNo(forDF: UInt64(list.count))
    for no in 0...max(oldLastNo, newLastNo) {
      _ = try Relation.deleteBytes(ctx, &handle, key: blockKey(term, no))
    }
    try writePacked(ctx, &handle, term: term, list, columns: columns, positions: positions)
  }

  // MARK: - Helpers

  private static func documentFrequency(
    _ resolver: some PageResolver, _ dict: TreeHandle, term: [UInt8]
  ) throws(DBError) -> UInt64 {
    guard let bytes = try Relation.getBytes(resolver, dict, key: term) else { return 0 }
    return decodeDF(bytes)
  }


  private static func readGlobal(
    _ resolver: some PageResolver, _ handle: TreeHandle, columns: Int
  ) throws(DBError) -> FTSGlobalStats {
    var global: FTSGlobalStats
    if let bytes = try Relation.getBytes(resolver, handle, key: globalKey) {
      global = try FTSGlobalStats.decode(bytes)
    } else {
      global = FTSGlobalStats(docCount: 0, totalFieldLengths: [])
    }
    if global.totalFieldLengths.count < columns {
      global.totalFieldLengths += Array(
        repeating: 0, count: columns - global.totalFieldLengths.count)
    }
    return global
  }

  private static func encodeDF(_ df: UInt64) -> [UInt8] {
    var out: [UInt8] = []
    Varint.append(df, to: &out)
    return out
  }

  private static func decodeDF(_ bytes: [UInt8]) -> UInt64 {
    var offset = 0
    return Varint.read(bytes, &offset) ?? 0
  }

  /// Forward record: `varint fieldCount || field lengths || varint termCount ||
  /// (varint len || term bytes)*`.
  private static func encodeForward(fieldLengths: [UInt32], terms: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    Varint.append(UInt64(fieldLengths.count), to: &out)
    for length in fieldLengths { Varint.append(UInt64(length), to: &out) }
    Varint.append(UInt64(terms.count), to: &out)
    for term in terms {
      Varint.append(UInt64(term.count), to: &out)
      out.append(contentsOf: term)
    }
    return out
  }

  private static func decodeForward(
    _ bytes: [UInt8]
  ) throws(DBError) -> (fieldLengths: [UInt32], terms: [[UInt8]]) {
    var offset = 0
    guard let fieldCount = Varint.read(bytes, &offset) else {
      throw DBError.integrityFailure("fts forward: missing field count")
    }
    var fieldLengths: [UInt32] = []
    for _ in 0..<Int(fieldCount) {
      guard let length = Varint.read(bytes, &offset) else {
        throw DBError.integrityFailure("fts forward: truncated field length")
      }
      fieldLengths.append(UInt32(truncatingIfNeeded: length))
    }
    guard let termCount = Varint.read(bytes, &offset) else {
      throw DBError.integrityFailure("fts forward: missing term count")
    }
    var terms: [[UInt8]] = []
    for _ in 0..<Int(termCount) {
      guard let length = Varint.read(bytes, &offset), offset + Int(length) <= bytes.count else {
        throw DBError.integrityFailure("fts forward: truncated term")
      }
      terms.append(Array(bytes[offset..<offset + Int(length)]))
      offset += Int(length)
    }
    return (fieldLengths, terms)
  }
}
