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
}

public struct RelationState: Sendable {
  var version: Catalog.VersionRow
  var tableRecords: [String: Catalog.TableRecord] = [:]
  var indexRecords: [String: Catalog.IndexRecord] = [:]
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
      indexes: indexRecords.mapValues(\.definition))
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
          try BTree.put(ctx: ctx, tree: &tree, key: keyBytes, value: valueBytes)
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
        result = .success(try BTree.delete(ctx: ctx, tree: &tree, key: keyBytes))
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
        if let ref = try BTree.get(resolver: resolver, tree: tree, key: keyBytes) {
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
        guard let ref = try BTree.get(resolver: resolver, tree: tree, key: keyBytes) else {
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
        do throws(DBError) { decoded = .success(try Catalog.decodeVersion(raw)) } catch {
          decoded = .failure(error)
        }
      }
      state.version = try decoded.get()
    }

    // Tables first (index records resolve table names through them).
    try scanKind(resolver, mainTree, kind: Catalog.kindTable) { name, valueBytes throws(DBError) in
      let record = try Catalog.decodeTable(valueBytes, name: name)
      state.tableRecords[name] = record
      state.handleBaselines[.table(record.tableId)] = record.handle
    }
    try scanKind(resolver, mainTree, kind: Catalog.kindIndex) { name, valueBytes throws(DBError) in
      let record = try Catalog.decodeIndex(valueBytes, name: name)
      state.indexRecords[name] = record
      state.handleBaselines[.index(record.indexId)] = record.handle
    }
    return state
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
        _ = try cursor.seek(raw)
        positioned = cursor.isValid
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    while positioned {
      let proceed: Bool? = try cursor.withCurrent { (key, ref) throws(DBError) in
        guard key.count >= 2, key[0] == Catalog.prefix, key[1] == kind else { return false }
        _ = upper
        let name = String(decoding: key[2...], as: UTF8.self)
        guard case .inline(let valueBytes) = ref else {
          // Catalog records are small; an overflow value means corruption.
          throw DBError.integrityFailure("catalog record \(name) not inline")
        }
        try body(name, valueBytes)
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
    for tableId in state.sequences.keys.sorted() {
      let value = state.sequences[tableId]!
      if state.sequenceBaselines[tableId] != value {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
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
    guard state.tableRecords[definition.name] == nil else {
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

  static func dropTable(_ ctx: TxnContext, name: String) throws(DBError) {
    var state = try ensureState(ctx)
    guard let record = state.tableRecords[name] else { throw DBError.noSuchTable(name) }
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
    state.schemaDirty = true

    ctx.meta.mainTree = main
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
        result = .success(try Catalog.decodeTable(raw, name: name))
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
        result = .success(try Catalog.decodeIndex(raw, name: name))
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
