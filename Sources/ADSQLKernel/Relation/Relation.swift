/// Per-transaction relational state and the catalog lifecycle.
///
/// A write transaction loads the full catalog from its own snapshot on first
/// relational use (the catalog is small; eager load keeps reasoning simple).
/// DDL/DML mutate the in-memory state; `serializeState` writes back changed
/// tree handles, sequences, and the version row at commit time — before
/// `FreeList.serialize`, which must remain the last mutation.
///
/// Everything here is value-typed so group commit's `TxnRestorePoint` can
/// capture and restore a failing request's relational delta by plain copy.
enum TreeKey: Hashable, Sendable {
  case table(UInt32)
  case index(UInt32)
  case ftsDict(UInt32)
  case ftsPostings(UInt32)
  case ftsStats(UInt32)
}

public struct RelationState: Sendable {
  var version: Catalog.VersionRow
  var tableRecords: [String: Catalog.TableRecord] = [:]
  var indexRecords: [String: Catalog.IndexRecord] = [:]
  var ftsRecords: [String: Catalog.FTSRecord] = [:]
  /// F6f memtable: documents buffered this transaction, flushed coalesced into a
  /// table's FTS trees at the first read of that table (`flushFTS`) or at commit
  /// (`serializeState`). Value-typed, so `TxnRestorePoint` snapshots/restores it
  /// for free on a group-commit rollback.
  var ftsBuffer: [String: [FTSIndex.PendingDoc]] = [:]
  /// Parsed trigger definitions keyed by name (re-parsed from the stored raw
  /// CREATE TRIGGER text at load time, like SQLite's `sqlite_schema`).
  var triggerRecords: [String: TriggerDefinition] = [:]
  /// Triggers added or dropped this transaction whose catalog row needs a
  /// write-back (value = the raw SQL text, or nil for a drop).
  var triggerWrites: [String: String?] = [:]
  /// Handle last persisted (nil = record not on disk yet).
  var handleBaselines: [TreeKey: TreeHandle?] = [:]
  /// AUTOINCREMENT high-water marks touched this transaction.
  var sequences: [UInt32: UInt64] = [:]
  var sequenceBaselines: [UInt32: UInt64] = [:]
  /// Set by DDL: bump catalogVersion at serialization.
  var schemaDirty = false

  var schema: Schema {
    Schema(
      catalogVersion: version.catalogVersion,
      tables: tableRecords.mapValues(\.definition),
      indexes: indexRecords.mapValues(\.definition),
      ftsTables: ftsRecords.mapValues(\.definition),
      triggers: triggerRecords)
  }

  func tableName(for id: UInt32) -> String? {
    tableRecords.first { $0.value.tableId == id }?.key
  }
}

enum Relation {
  // MARK: - Byte-array bridges over BTree (typed-throws-safe)

  static func putBytes(
    _ ctx: TxnContext, _ tree: inout TreeHandle, key: [UInt8], value: [UInt8]
  ) throws(DBError) {
    var failure: DBError?
    key.withUnsafeBytes { keyBytes in
      value.withUnsafeBytes { valueBytes in
        do throws(DBError) {
          unsafe try BTree.put(ctx: ctx, tree: &tree, key: keyBytes, value: valueBytes)
        } catch {
          failure = error
        }
      }
    }
    if let failure { throw failure }
  }

  @discardableResult
  static func deleteBytes(
    _ ctx: TxnContext, _ tree: inout TreeHandle, key: [UInt8]
  ) throws(DBError) -> Bool {
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        result = unsafe .success(try BTree.delete(ctx: ctx, tree: &tree, key: keyBytes))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Zero-copy point read: looks up `key` and hands its value to `body` as a
  /// mapped page span (no record copy); returns nil when the key is absent.
  /// The span is valid only for the duration of `body`.
  static func withRowValue<R>(
    _ resolver: some PageResolver, _ tree: TreeHandle, key: [UInt8],
    _ body: (BTree.ValueRef) throws(DBError) -> R
  ) throws(DBError) -> R? {
    var result: Result<R?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        if let ref = unsafe try BTree.get(resolver: resolver, tree: tree, key: keyBytes) {
          result = .success(try body(ref))
        }
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  static func getBytes(
    _ resolver: some PageResolver, _ tree: TreeHandle, key: [UInt8]
  ) throws(DBError) -> [UInt8]? {
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = unsafe try BTree.get(resolver: resolver, tree: tree, key: keyBytes) else {
          return
        }
        result = .success(try BTree.copyValue(ref, resolver: resolver))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  // MARK: - State lifecycle

  /// Loads the full catalog from a snapshot's main tree.
  static func loadState(
    resolver: some PageResolver, mainTree: TreeHandle
  ) throws(DBError) -> RelationState {
    var state = RelationState(version: Catalog.VersionRow())
    if let versionBytes = try getBytes(resolver, mainTree, key: Catalog.versionKey) {
      var decoded: Result<Catalog.VersionRow, DBError> = .success(Catalog.VersionRow())
      versionBytes.withUnsafeBytes { raw in
        do throws(DBError) { decoded = unsafe .success(try Catalog.decodeVersion(raw)) } catch {
          decoded = .failure(error)
        }
      }
      state.version = try decoded.get()
    }

    // Tables first (index records resolve table names through them).
    unsafe try scanKind(resolver, mainTree, kind: Catalog.kindTable) { name, valueBytes throws(DBError) in
      let record = unsafe try Catalog.decodeTable(valueBytes, name: name)
      state.tableRecords[name] = record
      state.handleBaselines[.table(record.tableId)] = record.handle
    }
    unsafe try scanKind(resolver, mainTree, kind: Catalog.kindIndex) { name, valueBytes throws(DBError) in
      let record = unsafe try Catalog.decodeIndex(valueBytes, name: name)
      state.indexRecords[name] = record
      state.handleBaselines[.index(record.indexId)] = record.handle
    }
    unsafe try scanKind(resolver, mainTree, kind: Catalog.kindFTS) { name, valueBytes throws(DBError) in
      let record = unsafe try Catalog.decodeFTS(valueBytes, name: name)
      state.ftsRecords[name] = record
      state.handleBaselines[.ftsDict(record.ftsId)] = record.dict
      state.handleBaselines[.ftsPostings(record.ftsId)] = record.postings
      state.handleBaselines[.ftsStats(record.ftsId)] = record.stats
    }
    // Triggers are stored as raw CREATE TRIGGER text and re-parsed here (like
    // SQLite's sqlite_schema). A stored row that already round-tripped through
    // the parser at create time re-parses cleanly; corruption surfaces as a
    // catchable DBError, not a trap.
    unsafe try scanKind(resolver, mainTree, kind: Catalog.kindTrigger) { name, valueBytes throws(DBError) in
      let text = unsafe String(decoding: valueBytes, as: UTF8.self)
      state.triggerRecords[name] = try parseTriggerText(text, expectedName: name)
    }
    return state
  }

  /// Re-parses a stored CREATE TRIGGER text into a `TriggerDefinition`,
  /// verifying the name matches its catalog key.
  static func parseTriggerText(
    _ text: String, expectedName: String
  ) throws(DBError) -> TriggerDefinition {
    guard case .createTrigger(let create) = try SQLParser.parseOne(text) else {
      throw DBError.integrityFailure("catalog: trigger \(expectedName) text is not CREATE TRIGGER")
    }
    guard create.definition.name == expectedName else {
      throw DBError.integrityFailure(
        "catalog: trigger name \(create.definition.name) ≠ key \(expectedName)")
    }
    return create.definition
  }

  private static func scanKind(
    _ resolver: some PageResolver, _ mainTree: TreeHandle, kind: UInt8,
    _ body: (String, UnsafeRawBufferPointer) throws(DBError) -> Void
  ) throws(DBError) {
    let (lower, upper) = Catalog.kindBounds(kind)
    var cursor = Cursor(resolver: resolver, tree: mainTree)
    var positioned = false
    var failure: DBError?
    lower.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        positioned = cursor.isValid
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    while positioned {
      let proceed: Bool? = unsafe try cursor.withCurrent { (key, ref) throws(DBError) in
        guard key.count >= 2, unsafe key[0] == Catalog.prefix, unsafe key[1] == kind else { return false }
        _ = upper
        let name = unsafe String(decoding: key[2...], as: UTF8.self)
        guard case .inline(let valueBytes) = ref else {
          // Catalog records are small; an overflow value means corruption.
          throw DBError.integrityFailure("catalog record \(name) not inline")
        }
        try valueBytes.withUnsafeBytes { (raw) throws(DBError) in unsafe try body(name, raw) }
        return true
      }
      guard proceed == true else { break }
      positioned = try cursor.next()
    }
  }

  /// Populates `ctx.relation` from the transaction's snapshot if needed.
  @discardableResult
  static func ensureState(_ ctx: TxnContext) throws(DBError) -> RelationState {
    if let state = ctx.relation { return state }
    let state = try loadState(resolver: ctx, mainTree: ctx.meta.mainTree)
    ctx.relation = state
    return state
  }

  // MARK: - Commit-time write-back

  /// Persists changed handles, sequences, and the version row into catalog
  /// rows. Runs after the user body (requestEpoch must be 0) and strictly
  /// before `FreeList.serialize`.
  static func serializeState(ctx: TxnContext) throws(DBError) {
    try flushAllFTS(ctx)  // F6f: flush buffered FTS docs into the trees before serializing handles.
    guard var state = ctx.relation else { return }
    var main = ctx.meta.mainTree

    for name in state.tableRecords.keys.sorted() {
      let record = state.tableRecords[name]!
      let key = TreeKey.table(record.tableId)
      if state.handleBaselines[key] != record.handle {
        try putBytes(ctx, &main, key: Catalog.tableKey(name), value: Catalog.encode(record))
        state.handleBaselines[key] = record.handle
      }
    }
    for name in state.indexRecords.keys.sorted() {
      let record = state.indexRecords[name]!
      let key = TreeKey.index(record.indexId)
      if state.handleBaselines[key] != record.handle {
        try putBytes(ctx, &main, key: Catalog.indexKey(name), value: Catalog.encode(record))
        state.handleBaselines[key] = record.handle
      }
    }
    for name in state.ftsRecords.keys.sorted() {
      let record = state.ftsRecords[name]!
      let dictKey = TreeKey.ftsDict(record.ftsId)
      let postKey = TreeKey.ftsPostings(record.ftsId)
      let statsKey = TreeKey.ftsStats(record.ftsId)
      if state.handleBaselines[dictKey] != record.dict
        || state.handleBaselines[postKey] != record.postings
        || state.handleBaselines[statsKey] != record.stats {
        try putBytes(ctx, &main, key: Catalog.ftsKey(name), value: Catalog.encode(record))
        state.handleBaselines[dictKey] = record.dict
        state.handleBaselines[postKey] = record.postings
        state.handleBaselines[statsKey] = record.stats
      }
    }
    for name in state.triggerWrites.keys.sorted() {
      let pending = state.triggerWrites[name]!
      if let text = pending {
        try putBytes(ctx, &main, key: Catalog.triggerKey(name), value: Array(text.utf8))
      } else {
        try deleteBytes(ctx, &main, key: Catalog.triggerKey(name))
      }
    }
    state.triggerWrites.removeAll(keepingCapacity: false)
    for tableId in state.sequences.keys.sorted() {
      let value = state.sequences[tableId]!
      if state.sequenceBaselines[tableId] != value {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { unsafe bytes.append(contentsOf: $0) }
        try putBytes(ctx, &main, key: Catalog.sequenceKey(tableId), value: bytes)
        state.sequenceBaselines[tableId] = value
      }
    }
    if state.schemaDirty {
      state.version.catalogVersion += 1
      try putBytes(ctx, &main, key: Catalog.versionKey, value: Catalog.encode(state.version))
      state.schemaDirty = false
    }

    ctx.meta.mainTree = main
    ctx.relation = state
  }

  // MARK: - DDL

  static func createTable(_ ctx: TxnContext, _ definition: TableDefinition) throws(DBError) {
    try definition.validate()
    var state = try ensureState(ctx)
    guard state.tableRecords[definition.name] == nil, state.ftsRecords[definition.name] == nil else {
      throw DBError.tableExists(definition.name)
    }
    guard definition.name.utf8.count <= 255 else {
      throw DBError.invalidDefinition("table name too long")
    }
    for fk in definition.foreignKeys {
      guard fk.parentTable == definition.name || state.tableRecords[fk.parentTable] != nil else {
        throw DBError.noSuchTable(fk.parentTable)
      }
    }
    let id = state.version.nextTableId
    state.version.nextTableId += 1
    state.tableRecords[definition.name] = Catalog.TableRecord(
      tableId: id, handle: .empty, definition: definition)
    state.handleBaselines[.table(id)] = nil as TreeHandle?
    state.schemaDirty = true
    ctx.relation = state
  }

  /// Creates an FTS virtual table: a catalog record owning three (initially
  /// empty) B+trees. Roots are allocated lazily on first write (F2), exactly
  /// like a table/index handle. No indexing here — F0 is foundations only.
  static func createVirtualTable(_ ctx: TxnContext, _ definition: FTSDefinition) throws(DBError) {
    var state = try ensureState(ctx)
    guard state.tableRecords[definition.name] == nil, state.ftsRecords[definition.name] == nil else {
      throw DBError.tableExists(definition.name)
    }
    guard definition.name.utf8.count <= 255 else {
      throw DBError.invalidDefinition("virtual table name too long")
    }
    guard !definition.columns.isEmpty else {
      throw DBError.invalidDefinition("fts5 table \(definition.name) has no columns")
    }
    for column in definition.columns where column.utf8.count > 255 {
      throw DBError.invalidDefinition("fts5 table \(definition.name): column name too long")
    }
    for token in definition.tokenize where token.utf8.count > 255 {
      throw DBError.invalidDefinition("fts5 table \(definition.name): tokenizer argument too long")
    }
    if case .external(let table, let rowid) = definition.content {
      guard table.utf8.count <= 255, rowid.utf8.count <= 255 else {
        throw DBError.invalidDefinition(
          "fts5 table \(definition.name): content table/rowid name too long")
      }
    }
    let id = state.version.nextTableId
    state.version.nextTableId += 1
    state.ftsRecords[definition.name] = Catalog.FTSRecord(
      ftsId: id, dict: .empty, postings: .empty, stats: .empty, definition: definition)
    state.handleBaselines[.ftsDict(id)] = nil as TreeHandle?
    state.handleBaselines[.ftsPostings(id)] = nil as TreeHandle?
    state.handleBaselines[.ftsStats(id)] = nil as TreeHandle?
    state.schemaDirty = true
    ctx.relation = state
  }

  static func dropTable(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    guard let record = state.tableRecords[name] else {
      // `DROP TABLE` also removes an FTS virtual table.
      if state.ftsRecords[name] != nil { return try dropVirtualTable(ctx, name: name) }
      throw DBError.noSuchTable(name)
    }
    // Another table referencing this one blocks the drop.
    for (otherName, other) in state.tableRecords where otherName != name {
      if other.definition.foreignKeys.contains(where: { $0.parentTable == name }) {
        throw DBError.foreignKeyViolation(table: otherName)
      }
    }
    var main = ctx.meta.mainTree

    let ownIndexes = state.indexRecords.filter { $0.value.tableId == record.tableId }
    for (indexName, indexRecord) in ownIndexes.sorted(by: { $0.key < $1.key }) {
      try freeTree(ctx, handle: indexRecord.handle)
      try deleteBytes(ctx, &main, key: Catalog.indexKey(indexName))
      state.indexRecords.removeValue(forKey: indexName)
      state.handleBaselines.removeValue(forKey: .index(indexRecord.indexId))
    }
    try freeTree(ctx, handle: record.handle)
    try deleteBytes(ctx, &main, key: Catalog.tableKey(name))
    try deleteBytes(ctx, &main, key: Catalog.sequenceKey(record.tableId))
    state.tableRecords.removeValue(forKey: name)
    state.handleBaselines.removeValue(forKey: .table(record.tableId))
    state.sequences.removeValue(forKey: record.tableId)
    state.sequenceBaselines.removeValue(forKey: record.tableId)
    // Triggers on this table go with it (SQLite drops dependent triggers).
    for triggerName in state.triggerRecords.keys.sorted()
    where state.triggerRecords[triggerName]!.table == name {
      state.triggerRecords.removeValue(forKey: triggerName)
      state.triggerWrites[triggerName] = nil as String?
    }
    state.schemaDirty = true

    ctx.meta.mainTree = main
    ctx.relation = state
  }

  /// Drops an FTS virtual table and frees the three trees it owns.
  static func dropVirtualTable(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    guard let record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
    var main = ctx.meta.mainTree
    try freeTree(ctx, handle: record.dict)
    try freeTree(ctx, handle: record.postings)
    try freeTree(ctx, handle: record.stats)
    try deleteBytes(ctx, &main, key: Catalog.ftsKey(name))
    state.ftsRecords.removeValue(forKey: name)
    state.handleBaselines.removeValue(forKey: .ftsDict(record.ftsId))
    state.handleBaselines.removeValue(forKey: .ftsPostings(record.ftsId))
    state.handleBaselines.removeValue(forKey: .ftsStats(record.ftsId))
    state.schemaDirty = true
    ctx.meta.mainTree = main
    ctx.relation = state
  }

  // MARK: - FTS maintenance (self-contained; F2b)

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
    ctx.meta.mainTree = main
    ctx.relation = state
  }

  // MARK: - Triggers (M5/F5)

  /// Registers a trigger: validates its name (unique across the table/index/
  /// fts/trigger namespace) and its target (an existing base table), then
  /// records it for write-back as raw CREATE TRIGGER text. No firing here —
  /// the DML path looks triggers up by (table, event) when rows change.
  static func createTrigger(_ ctx: TxnContext, _ definition: TriggerDefinition) throws(DBError) {
    var state = try ensureState(ctx)
    guard definition.name.utf8.count <= 255 else {
      throw DBError.invalidDefinition("trigger name too long")
    }
    guard state.triggerRecords[definition.name] == nil else {
      throw DBError.triggerExists(definition.name)
    }
    // Shared schema namespace (SQLite keeps triggers alongside tables/indexes).
    guard state.tableRecords[definition.name] == nil,
      state.indexRecords[definition.name] == nil,
      state.ftsRecords[definition.name] == nil else {
      throw DBError.invalidDefinition(
        "object named \(definition.name) already exists")
    }
    guard state.tableRecords[definition.table] != nil else {
      if state.ftsRecords[definition.table] != nil {
        throw DBError.invalidDefinition("cannot create trigger on virtual table \(definition.table)")
      }
      throw DBError.noSuchTable(definition.table)
    }
    state.triggerRecords[definition.name] = definition
    state.triggerWrites[definition.name] = definition.sql
    state.schemaDirty = true
    ctx.relation = state
  }

  static func dropTrigger(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    guard state.triggerRecords[name] != nil else { throw DBError.noSuchTrigger(name) }
    state.triggerRecords.removeValue(forKey: name)
    state.triggerWrites[name] = nil as String?
    state.schemaDirty = true
    ctx.relation = state
  }

  /// Single-record catalog fetches (read paths avoid full catalog loads).
  static func tableRecord(
    _ resolver: some PageResolver, mainTree: TreeHandle, name: String
  ) throws(DBError) -> Catalog.TableRecord? {
    guard let bytes = try getBytes(resolver, mainTree, key: Catalog.tableKey(name)) else {
      return nil
    }
    var result: Result<Catalog.TableRecord, DBError> = .failure(.noSuchTable(name))
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        result = unsafe .success(try Catalog.decodeTable(raw, name: name))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  static func indexRecord(
    _ resolver: some PageResolver, mainTree: TreeHandle, name: String
  ) throws(DBError) -> Catalog.IndexRecord? {
    guard let bytes = try getBytes(resolver, mainTree, key: Catalog.indexKey(name)) else {
      return nil
    }
    var result: Result<Catalog.IndexRecord, DBError> = .failure(.noSuchIndex(name))
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        result = unsafe .success(try Catalog.decodeIndex(raw, name: name))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Single-record FTS catalog fetch (the read path resolves an FTS table's
  /// dictionary/postings/stats roots without a full catalog load), mirroring
  /// `tableRecord`/`indexRecord`. nil when the FTS table is absent.
  static func ftsRecord(
    _ resolver: some PageResolver, mainTree: TreeHandle, name: String
  ) throws(DBError) -> Catalog.FTSRecord? {
    guard let bytes = try getBytes(resolver, mainTree, key: Catalog.ftsKey(name)) else {
      return nil
    }
    var result: Result<Catalog.FTSRecord, DBError> = .failure(.noSuchTable(name))
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        result = unsafe .success(try Catalog.decodeFTS(raw, name: name))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Returns every page of a tree (nodes + overflow) to the transaction.
  static func freeTree(_ ctx: TxnContext, handle: TreeHandle) throws(DBError) {
    guard handle.rootPage != 0 else { return }
    let report = try BTree.validate(resolver: ctx, tree: handle)
    for page in report.reachablePages.sorted() {
      ctx.freePage(page)
    }
  }
}
