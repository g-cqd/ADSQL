import Synchronization

/// Latest-schema cache shared by readers. MVCC-correct: a transaction reads
/// its snapshot's version row first and only reuses the cache on a match,
/// so old-generation readers reconstruct their own (older) schema instead
/// of seeing a newer one.
///
/// Catalog records (which embed per-generation tree handles) are cached per
/// COMMITTED GENERATION: any read at generation G can reuse a record loaded
/// by another read at G, eliminating per-call catalog descents on hot read
/// paths. A new commit simply starts a fresh per-generation map.
public final class SchemaCache: Sendable {
  private let cached = Mutex<Schema?>(nil)
  private struct Records {
    var generation: UInt64
    var tables: [String: Catalog.TableRecord] = [:]
    var indexes: [String: Catalog.IndexRecord] = [:]
  }
  private let records = Mutex<Records>(Records(generation: 0))

  public init() {}

  func tableRecord(
    _ resolver: some PageResolver, meta: Meta, name: String
  ) throws(DBError) -> Catalog.TableRecord? {
    let cachedRecord: Catalog.TableRecord? = records.withLock { state in
      state.generation == meta.generation ? state.tables[name] : nil
    }
    if let cachedRecord { return cachedRecord }
    // Misses (including absent tables) load fresh; only positive results
    // are cached.
    let loaded = try Relation.tableRecord(resolver, mainTree: meta.mainTree, name: name)
    if let loaded {
      records.withLock { state in
        if state.generation != meta.generation {
          if state.generation < meta.generation {
            state = Records(generation: meta.generation)
          } else {
            return
          }
        }
        state.tables[name] = loaded
      }
    }
    return loaded
  }

  func indexRecord(
    _ resolver: some PageResolver, meta: Meta, name: String
  ) throws(DBError) -> Catalog.IndexRecord? {
    let cachedRecord: Catalog.IndexRecord? = records.withLock { state in
      state.generation == meta.generation ? state.indexes[name] : nil
    }
    if let cachedRecord { return cachedRecord }
    let loaded = try Relation.indexRecord(resolver, mainTree: meta.mainTree, name: name)
    if let loaded {
      records.withLock { state in
        if state.generation != meta.generation {
          if state.generation < meta.generation {
            state = Records(generation: meta.generation)
          } else {
            return
          }
        }
        state.indexes[name] = loaded
      }
    }
    return loaded
  }

  func schema(resolver: some PageResolver, meta: Meta) throws(DBError) -> Schema {
    let version = try currentVersion(resolver: resolver, meta: meta)
    if let snapshot = cached.withLock({ $0 }), snapshot.catalogVersion == version {
      return snapshot
    }
    let loaded = try Relation.loadState(resolver: resolver, mainTree: meta.mainTree).schema
    cached.withLock { existing in
      if existing == nil || existing!.catalogVersion <= loaded.catalogVersion {
        existing = loaded
      }
    }
    return loaded
  }

  /// Writer-side publish after a DDL commit (already authoritative).
  func publish(_ schema: Schema) {
    cached.withLock { existing in
      if existing == nil || existing!.catalogVersion <= schema.catalogVersion {
        existing = schema
      }
    }
  }

  private func currentVersion(
    resolver: some PageResolver, meta: Meta
  ) throws(DBError) -> UInt64 {
    guard let bytes = try Relation.getBytes(resolver, meta.mainTree, key: Catalog.versionKey)
    else { return 0 }
    var result: Result<UInt64, DBError> = .success(0)
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        result = unsafe .success(try Catalog.decodeVersion(raw).catalogVersion)
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }
}

// MARK: - Public relational API

extension ReadTxn {
  /// The schema as of this snapshot.
  public func schema() throws(DBError) -> Schema {
    if let schemaCache {
      return try schemaCache.schema(resolver: resolver, meta: meta)
    }
    return try Relation.loadState(resolver: resolver, mainTree: meta.mainTree).schema
  }

  func tableRecord(_ name: String) throws(DBError) -> Catalog.TableRecord {
    let record =
      if let schemaCache {
        try schemaCache.tableRecord(resolver, meta: meta, name: name)
      } else {
        try Relation.tableRecord(resolver, mainTree: meta.mainTree, name: name)
      }
    guard let record else { throw DBError.noSuchTable(name) }
    return record
  }

  func indexRecord(_ name: String) throws(DBError) -> Catalog.IndexRecord {
    let record =
      if let schemaCache {
        try schemaCache.indexRecord(resolver, meta: meta, name: name)
      } else {
        try Relation.indexRecord(resolver, mainTree: meta.mainTree, name: name)
      }
    guard let record else { throw DBError.noSuchIndex(name) }
    return record
  }

  /// The catalog record (dictionary/postings/stats roots + config) of an FTS5
  /// table at this snapshot. Single-fetch (the schema cache covers tables and
  /// indexes only); the SELECT executor uses it to drive a MATCH source.
  func ftsRecord(_ name: String) throws(DBError) -> Catalog.FTSRecord {
    guard let record = try Relation.ftsRecord(resolver, mainTree: meta.mainTree, name: name) else {
      throw DBError.noSuchTable(name)
    }
    return record
  }

  /// Point lookup by rowid.
  public func row(in table: String, rowid: Int64) throws(DBError) -> Row? {
    try Relation.readRow(resolver, table: try tableRecord(table), rowid: rowid)
  }

  /// Number of rows in a table at this snapshot.
  public func rowCount(in table: String) throws(DBError) -> UInt64 {
    try tableRecord(table).handle.count
  }

  /// Forward scan over a table in rowid order.
  public func withRowCursor<R>(
    table: String, _ body: (inout RowCursor<CommittedResolver>) throws(DBError) -> R
  ) throws(DBError) -> R {
    var cursor = try RowCursor(
      resolver: resolver, table: try tableRecord(table), mode: .table,
      lowerKey: nil, upperKey: nil)
    return try body(&cursor)
  }

  /// Forward scan over an index within typed bounds.
  public func withIndexCursor<R>(
    index name: String, bounds: IndexBounds = .all, covering: [String]? = nil,
    _ body: (inout RowCursor<CommittedResolver>) throws(DBError) -> R
  ) throws(DBError) -> R {
    let index = try indexRecord(name)
    let table = try tableRecord(index.definition.table)
    if let covering {
      for column in covering where !index.definition.includes.contains(column) {
        throw DBError.invalidDefinition(
          "index-only scan of \(name) needs column \(column) in INCLUDE")
      }
    }
    let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
    var cursor = try RowCursor(
      resolver: resolver, table: table, mode: .index(index),
      lowerKey: lower, upperKey: upper,
      coveringIncludes: covering == nil ? nil : index.definition.includes)
    return try body(&cursor)
  }

  /// Unique-style point probe: rowid of the first entry matching all index
  /// columns exactly.
  public func firstRowid(index name: String, equals values: [Value]) throws(DBError) -> Int64? {
    let index = try indexRecord(name)
    let table = try tableRecord(index.definition.table)
    return try Relation.firstRowid(resolver, index: index, table: table, equals: values)
  }
}

extension WriteTxn {
  /// The schema as seen by this transaction (including its own DDL).
  public func schema() throws(DBError) -> Schema {
    try Relation.ensureState(ctx).schema
  }

  func tableRecord(_ name: String) throws(DBError) -> Catalog.TableRecord {
    guard let record = try Relation.ensureState(ctx).tableRecords[name] else {
      throw DBError.noSuchTable(name)
    }
    return record
  }

  func indexRecord(_ name: String) throws(DBError) -> Catalog.IndexRecord {
    guard let record = try Relation.ensureState(ctx).indexRecords[name] else {
      throw DBError.noSuchIndex(name)
    }
    return record
  }

  // MARK: DML

  /// Inserts a row; returns its rowid (nil when `.ignore` skipped a
  /// conflicting insert). Missing columns take their defaults.
  @discardableResult
  public func insert(
    into table: String, _ values: [String: Value],
    onConflict: ConflictPolicy = .abort
  ) throws(DBError) -> Int64? {
    try Relation.insert(ctx, into: table, values: values, onConflict: onConflict)
  }

  /// Inserts positionally: `columnSlots[i]` is the schema column index that
  /// `values[i]` targets (compute once per statement). Skips the name→value
  /// dictionary; same defaults/typing/conflict semantics as `insert`.
  @discardableResult
  public func insertAssembled(
    into table: String, columnSlots: [Int], values: [Value],
    onConflict: ConflictPolicy = .abort
  ) throws(DBError) -> Int64? {
    try Relation.insertAssembled(
      ctx, into: table, columnSlots: columnSlots, values: values, onConflict: onConflict)
  }

  /// Updates the given columns of one row. Returns false when the rowid
  /// does not exist.
  @discardableResult
  public func update(
    _ table: String, rowid: Int64, set: [String: Value]
  ) throws(DBError) -> Bool {
    try Relation.update(ctx, table: table, rowid: rowid, set: set)
  }

  /// Deletes one row. Returns false when the rowid does not exist.
  @discardableResult
  public func delete(from table: String, rowid: Int64) throws(DBError) -> Bool {
    try Relation.delete(ctx, from: table, rowid: rowid)
  }

  // MARK: Reads (through this transaction's own uncommitted state)

  public func row(in table: String, rowid: Int64) throws(DBError) -> Row? {
    try Relation.readRow(ctx, table: try tableRecord(table), rowid: rowid)
  }

  /// Number of rows in a table, including this transaction's writes.
  public func rowCount(in table: String) throws(DBError) -> UInt64 {
    try tableRecord(table).handle.count
  }

  public func withRowCursor<R>(
    table: String, _ body: (inout RowCursor<TxnContext>) throws(DBError) -> R
  ) throws(DBError) -> R {
    var cursor = try RowCursor(
      resolver: ctx, table: try tableRecord(table), mode: .table,
      lowerKey: nil, upperKey: nil)
    return try body(&cursor)
  }

  public func withIndexCursor<R>(
    index name: String, bounds: IndexBounds = .all,
    _ body: (inout RowCursor<TxnContext>) throws(DBError) -> R
  ) throws(DBError) -> R {
    let index = try indexRecord(name)
    let table = try tableRecord(index.definition.table)
    let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
    var cursor = try RowCursor(
      resolver: ctx, table: table, mode: .index(index),
      lowerKey: lower, upperKey: upper)
    return try body(&cursor)
  }

  public func firstRowid(index name: String, equals values: [Value]) throws(DBError) -> Int64? {
    let index = try indexRecord(name)
    let table = try tableRecord(index.definition.table)
    return try Relation.firstRowid(ctx, index: index, table: table, equals: values)
  }

  /// Creates a table. Transactional and crash-atomic like any other write.
  public func createTable(_ definition: TableDefinition) throws(DBError) {
    try Relation.createTable(ctx, definition)
  }

  /// Creates an FTS virtual table (its catalog record + three empty trees).
  public func createVirtualTable(_ definition: FTSDefinition) throws(DBError) {
    try Relation.createVirtualTable(ctx, definition)
  }

  // MARK: FTS maintenance + reads (F2b)

  public func ftsAdd(_ table: String, docid: Int64, columnTexts: [String]) throws(DBError) {
    try Relation.ftsAdd(ctx, name: table, docid: docid, columnTexts: columnTexts)
  }

  @discardableResult
  public func ftsRemove(_ table: String, docid: Int64) throws(DBError) -> Bool {
    try Relation.ftsRemove(ctx, name: table, docid: docid)
  }

  public func ftsNextRowid(_ table: String) throws(DBError) -> Int64 {
    try Relation.ftsNextRowid(ctx, name: table)
  }

  public func ftsRemoveAll(_ table: String) throws(DBError) {
    try Relation.ftsRemoveAll(ctx, name: table)
  }

  private func ftsRecord(_ name: String) throws(DBError) -> Catalog.FTSRecord {
    guard let record = try Relation.ensureState(ctx).ftsRecords[name] else {
      throw DBError.noSuchTable(name)
    }
    return record
  }

  public func ftsPostings(_ table: String, term: [UInt8]) throws(DBError) -> [FTSPosting]? {
    try FTSIndex.postings(ctx, ftsRecord(table), term: term)
  }

  public func ftsDocumentFrequency(_ table: String, term: [UInt8]) throws(DBError) -> UInt64 {
    try FTSIndex.documentFrequency(ctx, ftsRecord(table), term: term)
  }

  public func ftsGlobalStats(_ table: String) throws(DBError) -> FTSGlobalStats {
    try FTSIndex.globalStats(ctx, ftsRecord(table))
  }

  public func ftsDocStats(_ table: String, docid: Int64) throws(DBError) -> FTSDocStats? {
    try FTSIndex.docStats(ctx, ftsRecord(table), docid: docid)
  }

  /// Evaluates a MATCH query string against an FTS table → matching docids
  /// (ascending). Boolean membership only; ranking arrives in F4.
  public func ftsMatch(_ table: String, _ query: String) throws(DBError) -> [Int64] {
    try FTSMatch.evaluate(FTSQuery.parse(query), record: ftsRecord(table), resolver: ctx)
  }

  /// The bm25f score (F4a) of `docid` for a MATCH query string, under per-column
  /// `weights` (defaulting to all-ones for plain bm25). Negative: smaller is more
  /// relevant. Exposed for the scorer unit tests; the SQL `rank`/`bm25()` surface
  /// computes the same score in the executor.
  public func ftsScore(
    _ table: String, _ query: String, weights: [Double]? = nil, docid: Int64
  ) throws(DBError) -> Double {
    let record = try ftsRecord(table)
    let columns = record.definition.columns.count
    let resolved = weights ?? [Double](repeating: 1.0, count: columns)
    return try FTSScorer.score(
      FTSQuery.parse(query), record: record, resolver: ctx, docid: docid,
      weights: resolved, global: try FTSIndex.globalStats(ctx, record))
  }

  /// Drops a table, its indexes, and every page they own.
  public func dropTable(_ name: String) throws(DBError) {
    try Relation.dropTable(ctx, name: name)
  }

  /// Creates an index (backfilling from existing rows).
  public func createIndex(_ definition: IndexDefinition) throws(DBError) {
    try Relation.createIndex(ctx, definition)
  }

  public func dropIndex(_ name: String) throws(DBError) {
    try Relation.dropIndex(ctx, name: name)
  }

  /// Registers a row trigger (M5/F5); its body fires in the DML path.
  public func createTrigger(_ definition: TriggerDefinition) throws(DBError) {
    try Relation.createTrigger(ctx, definition)
  }

  public func dropTrigger(_ name: String) throws(DBError) {
    try Relation.dropTrigger(ctx, name: name)
  }
}
