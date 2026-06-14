/// FTS5 index maintenance for the storage layer (RFC 0009 H2/R4 — split from
/// Relation.swift). `ftsAdd`/`ftsRemove` and the dictionary + postings + stats
/// tree updates that keep an FTS5 virtual table's three trees consistent as
/// documents are indexed and removed. An `enum Relation` extension; code motion.
extension Relation {
  /// Indexes a document into an FTS table. Mutates the record's three tree
  /// handles; `serializeState` persists them like any other catalog change.
  static func ftsAdd(
    _ ctx: TxnContext, name: String, docid: Int64, columnTexts: [String]
  ) throws(DBError) {
    var state = try ensureState(ctx)
    guard state.ftsRecords[name] != nil else { throw DBError.noSuchTable(name) }
    // F6f: buffer the document; the coalesced batch is written by `flushFTS` at
    // the next read of this table or at commit. No tree writes here.
    state.ftsBuffer[name, default: []].append(
      FTSIndex.PendingDoc(docid: docid, columnTexts: columnTexts))
    ctx.relation = state
  }

  /// Flushes one FTS table's buffered docs (F6f) into its trees in a single
  /// coalesced batch. No-op when the buffer is empty.
  static func flushFTS(_ ctx: TxnContext, name: String) throws(DBError) {
    guard var state = ctx.relation, let pending = state.ftsBuffer[name], !pending.isEmpty
    else { return }
    guard var record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
    // `addBatch` mutates `record` + the trees (via `ctx`), never `ctx.relation`,
    // so writing the local `state` back afterward is correct.
    try FTSIndex.addBatch(ctx, record: &record, docs: pending)
    state.ftsRecords[name] = record
    state.ftsBuffer[name] = nil
    ctx.relation = state
  }

  /// Flushes every buffered FTS table (the commit path, via `serializeState`).
  static func flushAllFTS(_ ctx: TxnContext) throws(DBError) {
    guard let buffer = ctx.relation?.ftsBuffer, !buffer.isEmpty else { return }
    for name in buffer.keys.sorted() { try flushFTS(ctx, name: name) }
  }

  /// Removes a document from an FTS table; returns false when it wasn't present.
  @discardableResult
  static func ftsRemove(_ ctx: TxnContext, name: String, docid: Int64) throws(DBError) -> Bool {
    try flushFTS(ctx, name: name)  // F6f: the doc may be buffered — write it before removing.
    var state = try ensureState(ctx)
    guard var record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
    let removed = try FTSIndex.remove(ctx, record: &record, docid: docid)
    state.ftsRecords[name] = record
    ctx.relation = state
    return removed
  }

  /// The next auto docid for an FTS table (max stored docid + 1).
  static func ftsNextRowid(_ ctx: TxnContext, name: String) throws(DBError) -> Int64 {
    let state = try ensureState(ctx)
    guard let record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
    let treeNext = try FTSIndex.nextRowid(ctx, statsHandle: record.stats)
    // F6f: buffered (not-yet-flushed) docs aren't in the stats tree — consult the
    // buffer's max docid so batched auto-rowid inserts don't collide.
    let bufferMax = state.ftsBuffer[name]?.lazy.map(\.docid).max() ?? 0
    return max(treeNext, bufferMax + 1)
  }

  /// Clears an FTS table's index (the `'delete-all'` command).
  static func ftsRemoveAll(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    state.ftsBuffer[name] = nil  // F6f: drop buffered docs too (delete-all clears everything).
    guard var record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
    try FTSIndex.removeAll(ctx, record: &record)
    state.ftsRecords[name] = record
    ctx.relation = state
  }

  static func createIndex(_ ctx: TxnContext, _ definition: IndexDefinition) throws(DBError) {
    var state = try ensureState(ctx)
    guard state.indexRecords[definition.name] == nil else {
      throw DBError.indexExists(definition.name)
    }
    guard definition.name.utf8.count <= 255 else {
      throw DBError.invalidDefinition("index name too long")
    }
    guard let table = state.tableRecords[definition.table] else {
      throw DBError.noSuchTable(definition.table)
    }
    try definition.validate(against: table.definition)

    let id = state.version.nextIndexId
    state.version.nextIndexId += 1
    var record = Catalog.IndexRecord(
      indexId: id, tableId: table.tableId, handle: .empty, definition: definition)
    if table.handle.count > 0 {
      record.handle = try backfillIndex(ctx, state: state, table: table, definition: definition)
    }
    state.indexRecords[definition.name] = record
    state.handleBaselines[.index(id)] = nil as TreeHandle?
    state.schemaDirty = true
    ctx.hoistedRoster.removeAll(keepingCapacity: true)
    ctx.relation = state
  }

  static func dropIndex(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    guard let record = state.indexRecords[name] else { throw DBError.noSuchIndex(name) }
    var main = ctx.meta.mainTree
    try freeTree(ctx, handle: record.handle)
    try deleteBytes(ctx, &main, key: Catalog.indexKey(name))
    state.indexRecords.removeValue(forKey: name)
    state.handleBaselines.removeValue(forKey: .index(record.indexId))
    state.schemaDirty = true
    ctx.hoistedRoster.removeAll(keepingCapacity: true)
    ctx.meta.mainTree = main
    ctx.relation = state
  }
}
