/// FTS index build + maintenance (M5/F2b). Drives a tokenized document into the
/// three per-FTS-table B+trees the catalog `FTSRecord` owns:
///
///   - **dict**: `term → varint df` (df == posting-list length; re-derived each
///     write so it never drifts). Gives F3 prefix-term enumeration + IDF without
///     decoding postings.
///   - **postings**: `term → block-compressed posting list` (F2a `FTSPostings`).
///   - **stats**: `rowKey(docid) → forward record` (field lengths + the doc's
///     distinct terms — the delete companion) and `[0x00] → global aggregates`.
///
/// Maintenance is read-modify-write per term, mirroring the secondary-index loops
/// (`DML.swift`). Self-contained content only; segments/merge are a deferred perf
/// pass (a single list per term is correct, not yet write-optimal).
enum FTSIndex {
  /// Tokens longer than this are skipped (kept out of the term keyspace); they
  /// still count toward field length. B+tree keys are bounded by `maxKeySize`.
  static let maxTermBytes = 256
  /// Global-aggregates key. One byte sorts before every 8-byte `rowKey`, so a
  /// `move(to: .last)` on the stats tree lands on the largest docid.
  static let globalKey: [UInt8] = [0x00]

  // MARK: - Build

  static func add(
    _ ctx: TxnContext, record: inout Catalog.FTSRecord, docid: Int64, columnTexts: [String]
  ) throws(DBError) {
    let columns = record.definition.columns.count
    let storePositions = record.definition.detail != .none
    let docKey = KeyCodec.rowKey(docid)
    if try Relation.getBytes(ctx, record.stats, key: docKey) != nil {
      throw DBError.invalidDefinition("fts \(record.definition.name): docid \(docid) already indexed")
    }
    let tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)

    var fieldLengths = [UInt32](repeating: 0, count: columns)
    var termInfo: [[UInt8]: (fieldTFs: [UInt32], positions: [[UInt32]])] = [:]
    for column in 0..<min(columns, columnTexts.count) {
      try tokenizer.tokenize(Array(columnTexts[column].utf8)) { (token) throws(DBError) in
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

    var dict = record.dict
    var postings = record.postings
    var stats = record.stats
    for (term, info) in termInfo {
      let posting = FTSPosting(
        docid: docid, fieldTFs: info.fieldTFs, positions: storePositions ? info.positions : [])
      var list = try decodePostings(ctx, postings, term: term, columns: columns, positions: storePositions)
      insertInDocidOrder(&list, posting)
      try Relation.putBytes(
        ctx, &postings, key: term,
        value: FTSPostings.encode(list, columns: columns, storePositions: storePositions))
      try Relation.putBytes(ctx, &dict, key: term, value: encodeDF(UInt64(list.count)))
    }

    try Relation.putBytes(
      ctx, &stats, key: docKey,
      value: encodeForward(fieldLengths: fieldLengths, terms: Array(termInfo.keys)))
    var global = try readGlobal(ctx, stats, columns: columns)
    global.docCount += 1
    for column in 0..<columns { global.totalFieldLengths[column] += UInt64(fieldLengths[column]) }
    try Relation.putBytes(ctx, &stats, key: globalKey, value: global.encode())

    record.dict = dict
    record.postings = postings
    record.stats = stats
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
      var list = try decodePostings(ctx, postings, term: term, columns: columns, positions: storePositions)
      list.removeAll { $0.docid == docid }
      if list.isEmpty {
        _ = try Relation.deleteBytes(ctx, &postings, key: term)
        _ = try Relation.deleteBytes(ctx, &dict, key: term)
      } else {
        try Relation.putBytes(
          ctx, &postings, key: term,
          value: FTSPostings.encode(list, columns: columns, storePositions: storePositions))
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
    guard let bytes = try Relation.getBytes(resolver, record.postings, key: term) else { return nil }
    return try FTSPostings.decode(
      bytes, columns: record.definition.columns.count,
      storePositions: record.definition.detail != .none)
  }

  static func documentFrequency(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> UInt64 {
    guard let bytes = try Relation.getBytes(resolver, record.dict, key: term) else { return 0 }
    return decodeDF(bytes)
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

  // MARK: - Helpers

  private static func decodePostings(
    _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8], columns: Int, positions: Bool
  ) throws(DBError) -> [FTSPosting] {
    guard let bytes = try Relation.getBytes(resolver, handle, key: term) else { return [] }
    return try FTSPostings.decode(bytes, columns: columns, storePositions: positions)
  }

  private static func insertInDocidOrder(_ list: inout [FTSPosting], _ posting: FTSPosting) {
    var low = 0
    var high = list.count
    while low < high {
      let mid = (low + high) / 2
      if list[mid].docid < posting.docid { low = mid + 1 } else { high = mid }
    }
    list.insert(posting, at: low)
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
