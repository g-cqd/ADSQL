/// Row-level operations: insert/update/delete with strict typing, defaults,
/// conflict policies, and index maintenance. All semantics mirror SQLite
/// where externally visible (NULLs never collide in UNIQUE indexes, NaN
/// stores as NULL, OR REPLACE deletes every conflicting row first).
extension Relation {
  // MARK: - Row assembly

  /// Ordered row values from a name→value dictionary: defaults materialized,
  /// strict types enforced, NaN normalized to NULL. Returns the explicit
  /// rowid when the rowid-alias column was supplied.
  static func assembleRow(
    table: Catalog.TableRecord, values: [String: Value]
  ) throws(DBError) -> (row: [Value], explicitRowid: Int64?) {
    let definition = table.definition
    for name in values.keys where definition.columnIndex(of: name) == nil {
      throw DBError.noSuchColumn(table: definition.name, column: name)
    }
    let aliasIndex = definition.rowidAliasIndex
    var explicitRowid: Int64?
    var row: [Value] = []
    row.reserveCapacity(definition.columns.count)

    for (index, column) in definition.columns.enumerated() {
      var value: Value
      if let provided = values[column.name] {
        value = provided
      } else {
        switch column.defaultValue {
        case .value(let v): value = v
        case .datetimeNow: value = .text(CivilTime.utcNowString())
        case nil: value = .null
        }
      }
      if case .real(let d) = value, d.isNaN {
        value = .null // SQLite stores NaN as NULL
      }
      if index == aliasIndex {
        // NULL means "assign for me" (SQLite rowid-alias semantics).
        if case .integer(let id) = value {
          explicitRowid = id
        } else if !value.isNull {
          throw DBError.typeMismatch(
            table: definition.name, column: column.name,
            expected: "INTEGER", got: value.typeName)
        }
        row.append(.null) // overwritten with the final rowid below
        continue
      }
      if !value.isNull, let type = value.columnType, type != column.type {
        throw DBError.typeMismatch(
          table: definition.name, column: column.name,
          expected: column.type.name, got: value.typeName)
      }
      if value.isNull && column.notNull {
        throw DBError.notNullViolation(table: definition.name, column: column.name)
      }
      row.append(value)
    }
    return (row, explicitRowid)
  }

  /// Decoded row padded to the schema (missing trailing columns become
  /// DEFAULT/NULL) with the rowid alias filled in.
  static func materializeRow(
    table: Catalog.TableRecord, rowid: Int64, recordBytes: [UInt8]
  ) throws(DBError) -> [Value] {
    var decoded: Result<[Value], DBError> = .success([])
    recordBytes.withUnsafeBytes { raw in
      do throws(DBError) { decoded = .success(try RecordCodec.decode(raw)) } catch {
        decoded = .failure(error)
      }
    }
    var row = try decoded.get()
    let columns = table.definition.columns
    guard row.count <= columns.count else {
      throw DBError.integrityFailure("row in \(table.definition.name) has too many columns")
    }
    while row.count < columns.count {
      switch columns[row.count].defaultValue {
      case .value(let v): row.append(v)
      case .datetimeNow, nil: row.append(.null)
      }
    }
    if let aliasIndex = table.definition.rowidAliasIndex {
      row[aliasIndex] = .integer(rowid)
    }
    return row
  }

  // MARK: - Index keys

  static func indexCollations(
    _ index: IndexDefinition, table: TableDefinition
  ) -> [Collation] {
    index.columns.map { name in
      table.columns[table.columnIndex(of: name)!].collation
    }
  }

  static func indexColumnValues(
    _ index: IndexDefinition, table: TableDefinition, row: [Value]
  ) -> [Value] {
    index.columns.map { row[table.columnIndex(of: $0)!] }
  }

  /// Full index entry key: encoded column values + rowid suffix.
  static func indexEntryKey(
    index: Catalog.IndexRecord, table: Catalog.TableRecord, row: [Value], rowid: Int64
  ) throws(DBError) -> [UInt8] {
    let values = indexColumnValues(index.definition, table: table.definition, row: row)
    var key = try KeyCodec.encode(
      values, collations: indexCollations(index.definition, table: table.definition))
    KeyCodec.appendRowidSuffix(rowid, to: &key)
    guard key.count <= Format.maxKeySize else {
      throw DBError.indexKeyTooLarge(index: index.definition.name, size: key.count)
    }
    return key
  }

  /// Rowid of a row whose values collide in a unique index (NULLs never
  /// collide). `excluding` skips the row being updated.
  static func uniqueConflict(
    _ resolver: some PageResolver, index: Catalog.IndexRecord, table: Catalog.TableRecord,
    row: [Value], excluding: Int64? = nil
  ) throws(DBError) -> Int64? {
    let values = indexColumnValues(index.definition, table: table.definition, row: row)
    guard !values.contains(where: \.isNull) else { return nil }
    let prefix = try KeyCodec.encode(
      values, collations: indexCollations(index.definition, table: table.definition))
    var cursor = Cursor(resolver: resolver, tree: index.handle)
    var outcome: Result<Int64?, DBError> = .success(nil)
    prefix.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = try cursor.seek(raw)
        guard cursor.isValid else { return }
        let hit: Int64?? = try cursor.withCurrent { (key, _) throws(DBError) in
          guard key.count == prefix.count + 8,
            prefix.withUnsafeBytes({ p in
              key.prefix(prefix.count).elementsEqual(UnsafeRawBufferPointer(rebasing: p[...]))
            })
          else { return nil }
          return KeyCodec.rowid(fromSuffixOf: key)
        }
        if let rowid = hit ?? nil, rowid != excluding {
          outcome = .success(rowid)
        }
      } catch {
        outcome = .failure(error)
      }
    }
    return try outcome.get()
  }

  // MARK: - Rowid allocation

  /// The AUTOINCREMENT high-water, loading the persisted row on first use
  /// (caching 0 with a 0 baseline when absent, so serialization skips it).
  static func currentSequence(
    _ ctx: TxnContext, state: inout RelationState, tableId: UInt32
  ) throws(DBError) -> UInt64 {
    if let cached = state.sequences[tableId] { return cached }
    if let bytes = try getBytes(ctx, ctx.meta.mainTree, key: Catalog.sequenceKey(tableId)),
      bytes.count >= 8 {
      let value = bytes.withUnsafeBytes {
        UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
      }
      state.sequences[tableId] = value
      state.sequenceBaselines[tableId] = value
      return value
    }
    state.sequences[tableId] = 0
    state.sequenceBaselines[tableId] = 0
    return 0
  }

  static func allocateRowid(
    _ ctx: TxnContext, state: inout RelationState, table: Catalog.TableRecord
  ) throws(DBError) -> Int64 {
    if table.definition.isAutoincrement {
      let sequence = try currentSequence(ctx, state: &state, tableId: table.tableId)
      guard sequence < UInt64(Int64.max) else {
        throw DBError.invalidDefinition("AUTOINCREMENT exhausted for \(table.definition.name)")
      }
      state.sequences[table.tableId] = sequence + 1
      return Int64(sequence + 1)
    }

    // Plain rowid tables: SQLite's max(rowid)+1, including reuse after the
    // max row is deleted — so probe every time (mmap-hot, O(depth)).
    var cursor = Cursor(resolver: ctx, tree: table.handle)
    var next: Int64 = 1
    if try cursor.move(to: .last) {
      let last: Int64?? = try cursor.withCurrent { (key, _) throws(DBError) in
        KeyCodec.rowid(fromSuffixOf: key)
      }
      if let maxRowid = last ?? nil {
        guard maxRowid < Int64.max else {
          throw DBError.invalidDefinition("rowid space exhausted for \(table.definition.name)")
        }
        next = maxRowid + 1
      }
    }
    return next
  }

  /// Explicit rowids above the AUTOINCREMENT high-water advance it — but
  /// only relative to the PERSISTED value (an unloaded sequence must never
  /// be rewound by a small explicit id).
  static func noteExplicitRowid(
    _ ctx: TxnContext, state: inout RelationState, table: Catalog.TableRecord, rowid: Int64
  ) throws(DBError) {
    guard table.definition.isAutoincrement, rowid > 0 else { return }
    let current = try currentSequence(ctx, state: &state, tableId: table.tableId)
    if UInt64(rowid) > current {
      state.sequences[table.tableId] = UInt64(rowid)
    }
  }

  // MARK: - Insert

  @discardableResult
  static func insert(
    _ ctx: TxnContext, into tableName: String, values: [String: Value],
    onConflict: ConflictPolicy
  ) throws(DBError) -> Int64? {
    var state = try ensureState(ctx)
    guard var table = state.tableRecords[tableName] else {
      throw DBError.noSuchTable(tableName)
    }
    var (row, explicitRowid) = try assembleRow(table: table, values: values)

    let rowid: Int64
    if let explicitRowid {
      rowid = explicitRowid
      try noteExplicitRowid(ctx, state: &state, table: table, rowid: rowid)
    } else {
      rowid = try allocateRowid(ctx, state: &state, table: table)
    }
    if let aliasIndex = table.definition.rowidAliasIndex {
      row[aliasIndex] = .integer(rowid)
    }

    // Conflict scan: explicit rowid collision + every unique index.
    var conflicts: [(rowid: Int64, index: String)] = []
    if explicitRowid != nil,
      try getBytes(ctx, table.handle, key: KeyCodec.rowKey(rowid)) != nil {
      conflicts.append((rowid: rowid, index: "rowid"))
    }
    let ownIndexes = state.indexRecords.values
      .filter { $0.tableId == table.tableId }
      .sorted { $0.definition.name < $1.definition.name }
    for index in ownIndexes where index.definition.unique {
      if let conflicting = try uniqueConflict(ctx, index: index, table: table, row: row) {
        conflicts.append((rowid: conflicting, index: index.definition.name))
      }
    }

    if !conflicts.isEmpty {
      switch onConflict {
      case .abort:
        throw DBError.uniqueViolation(table: tableName, index: conflicts[0].index)
      case .ignore:
        // SQLite consumes no rowid/sequence on an ignored insert: the local
        // state copy (with its allocation) is simply discarded.
        return nil
      case .replace:
        ctx.relation = state
        var victims = Set(conflicts.map(\.rowid))
        victims.remove(rowid) // same-rowid victim handled by overwrite below
        for victim in victims.sorted() {
          _ = try delete(ctx, from: tableName, rowid: victim)
        }
        // Same-rowid conflict: remove the old row's index entries first.
        if conflicts.contains(where: { $0.rowid == rowid }) {
          _ = try delete(ctx, from: tableName, rowid: rowid)
        }
        state = ctx.relation!
        table = state.tableRecords[tableName]!
      }
    }

    // Write the record + all index entries.
    var handle = table.handle
    try putBytes(ctx, &handle, key: KeyCodec.rowKey(rowid), value: RecordCodec.encode(row))
    table.handle = handle
    state.tableRecords[tableName] = table

    for indexName in state.indexRecords.keys.sorted() {
      guard state.indexRecords[indexName]!.tableId == table.tableId else { continue }
      var index = state.indexRecords[indexName]!
      let key = try indexEntryKey(index: index, table: table, row: row, rowid: rowid)
      var indexHandle = index.handle
      try putBytes(ctx, &indexHandle, key: key, value: [])
      index.handle = indexHandle
      state.indexRecords[indexName] = index
    }

    ctx.relation = state
    return rowid
  }

  // MARK: - Delete

  @discardableResult
  static func delete(
    _ ctx: TxnContext, from tableName: String, rowid: Int64
  ) throws(DBError) -> Bool {
    var state = try ensureState(ctx)
    guard var table = state.tableRecords[tableName] else {
      throw DBError.noSuchTable(tableName)
    }
    guard let recordBytes = try getBytes(ctx, table.handle, key: KeyCodec.rowKey(rowid)) else {
      return false
    }
    let row = try materializeRow(table: table, rowid: rowid, recordBytes: recordBytes)

    for indexName in state.indexRecords.keys.sorted() {
      guard state.indexRecords[indexName]!.tableId == table.tableId else { continue }
      var index = state.indexRecords[indexName]!
      let key = try indexEntryKey(index: index, table: table, row: row, rowid: rowid)
      var indexHandle = index.handle
      let removed = try deleteBytes(ctx, &indexHandle, key: key)
      guard removed else {
        throw DBError.integrityFailure(
          "index \(indexName) missing entry for \(tableName) rowid \(rowid)")
      }
      index.handle = indexHandle
      state.indexRecords[indexName] = index
    }

    var handle = table.handle
    _ = try deleteBytes(ctx, &handle, key: KeyCodec.rowKey(rowid))
    table.handle = handle
    state.tableRecords[tableName] = table
    ctx.relation = state
    return true
  }

  // MARK: - Update

  @discardableResult
  static func update(
    _ ctx: TxnContext, table tableName: String, rowid: Int64, set: [String: Value]
  ) throws(DBError) -> Bool {
    var state = try ensureState(ctx)
    guard var table = state.tableRecords[tableName] else {
      throw DBError.noSuchTable(tableName)
    }
    let definition = table.definition
    guard let recordBytes = try getBytes(ctx, table.handle, key: KeyCodec.rowKey(rowid)) else {
      return false
    }
    let oldRow = try materializeRow(table: table, rowid: rowid, recordBytes: recordBytes)

    var newRow = oldRow
    for (name, provided) in set {
      guard let columnIndex = definition.columnIndex(of: name) else {
        throw DBError.noSuchColumn(table: tableName, column: name)
      }
      if columnIndex == definition.rowidAliasIndex {
        throw DBError.invalidDefinition(
          "updating the rowid alias is unsupported; delete and reinsert")
      }
      let column = definition.columns[columnIndex]
      var value = provided
      if case .real(let d) = value, d.isNaN { value = .null }
      if !value.isNull, let type = value.columnType, type != column.type {
        throw DBError.typeMismatch(
          table: tableName, column: name, expected: column.type.name, got: value.typeName)
      }
      if value.isNull && column.notNull {
        throw DBError.notNullViolation(table: tableName, column: name)
      }
      newRow[columnIndex] = value
    }

    // Index maintenance for changed keys only, with unique pre-checks.
    let ownIndexNames = state.indexRecords.keys.sorted().filter {
      state.indexRecords[$0]!.tableId == table.tableId
    }
    var changedIndexes: [(name: String, oldKey: [UInt8], newKey: [UInt8])] = []
    for indexName in ownIndexNames {
      let index = state.indexRecords[indexName]!
      let oldKey = try indexEntryKey(index: index, table: table, row: oldRow, rowid: rowid)
      let newKey = try indexEntryKey(index: index, table: table, row: newRow, rowid: rowid)
      if oldKey != newKey {
        if index.definition.unique,
          let conflicting = try uniqueConflict(
            ctx, index: index, table: table, row: newRow, excluding: rowid) {
          _ = conflicting
          throw DBError.uniqueViolation(table: tableName, index: indexName)
        }
        changedIndexes.append((name: indexName, oldKey: oldKey, newKey: newKey))
      }
    }

    for change in changedIndexes {
      var index = state.indexRecords[change.name]!
      var indexHandle = index.handle
      let removed = try deleteBytes(ctx, &indexHandle, key: change.oldKey)
      guard removed else {
        throw DBError.integrityFailure(
          "index \(change.name) missing entry for \(tableName) rowid \(rowid)")
      }
      try putBytes(ctx, &indexHandle, key: change.newKey, value: [])
      index.handle = indexHandle
      state.indexRecords[change.name] = index
    }

    var handle = table.handle
    try putBytes(ctx, &handle, key: KeyCodec.rowKey(rowid), value: RecordCodec.encode(newRow))
    table.handle = handle
    state.tableRecords[tableName] = table
    ctx.relation = state
    return true
  }

  // MARK: - Index backfill (createIndex on a populated table)

  static func backfillIndex(
    _ ctx: TxnContext, state: RelationState, table: Catalog.TableRecord,
    definition: IndexDefinition
  ) throws(DBError) -> TreeHandle {
    var handle = TreeHandle.empty
    let probe = Catalog.IndexRecord(
      indexId: 0, tableId: table.tableId, handle: handle, definition: definition)
    var cursor = Cursor(resolver: ctx, tree: table.handle)
    var positioned = try cursor.move(to: .first)
    while positioned {
      let entry: (rowid: Int64, bytes: [UInt8])? = try cursor.withCurrent {
        (key, ref) throws(DBError) in
        guard let rowid = KeyCodec.rowid(fromSuffixOf: key) else {
          throw DBError.integrityFailure("malformed row key in \(table.definition.name)")
        }
        return (rowid: rowid, bytes: try BTree.copyValue(ref, resolver: ctx))
      }
      guard let entry else { break }
      let row = try materializeRow(table: table, rowid: entry.rowid, recordBytes: entry.bytes)
      if definition.unique {
        var withHandle = probe
        withHandle.handle = handle
        if try uniqueConflict(ctx, index: withHandle, table: table, row: row) != nil {
          throw DBError.uniqueViolation(table: table.definition.name, index: definition.name)
        }
      }
      var withHandle = probe
      withHandle.handle = handle
      let key = try indexEntryKey(index: withHandle, table: table, row: row, rowid: entry.rowid)
      try putBytes(ctx, &handle, key: key, value: [])
      positioned = try cursor.next()
    }
    return handle
  }
}
