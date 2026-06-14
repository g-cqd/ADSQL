/// Row delete + update for the storage layer (RFC 0009 H2/R4 — split from
/// DML.swift). `deleteRowCore`/`delete` (the physical single-row delete with index
/// maintenance + ON DELETE cascade/restrict actions) and the two-phase row
/// `update` (index + FK upkeep). An `extension Relation`; code motion + visibility.
extension Relation {
    /// Physical single-row delete + index maintenance (no FK actions).
    @discardableResult
    static func deleteRowCore(
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
        // The deleted row may have been the max rowid; a plain rowid table reuses it,
        // so drop the cache and let the next allocation re-probe (matches SQLite).
        state.maxRowidCache[table.tableId] = nil
        ctx.relation = state
        // AFTER DELETE row triggers: OLD = the removed row. Fires for direct
        // deletes, FK cascades, and OR REPLACE victims (all route through here),
        // matching SQLite.
        try TriggerEngine.fire(ctx, event: .delete, table: tableName, old: row, new: nil)
        return true
    }

    /// Row delete with ON DELETE actions (cascade chains, restrict checks).
    @discardableResult
    static func delete(
        _ ctx: TxnContext, from tableName: String, rowid: Int64
    ) throws(DBError) -> Bool {
        guard try deleteRowCore(ctx, from: tableName, rowid: rowid) else { return false }
        try processDeleteActions(ctx, deleted: [(table: tableName, rowid: rowid)])
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
        // An entry is rewritten when its key changes, or — for a covering index —
        // when only its stored INCLUDE value changes (key-stable, value-only update).
        var changedIndexes: [(name: String, oldKey: [UInt8], newKey: [UInt8], keyChanged: Bool)] = []
        for indexName in ownIndexNames {
            let index = state.indexRecords[indexName]!
            let oldKey = try indexEntryKey(index: index, table: table, row: oldRow, rowid: rowid)
            let newKey = try indexEntryKey(index: index, table: table, row: newRow, rowid: rowid)
            let keyChanged = oldKey != newKey
            let valueChanged =
                !index.definition.includes.isEmpty
                && indexEntryValue(index: index, table: table, row: oldRow)
                    != indexEntryValue(index: index, table: table, row: newRow)
            guard keyChanged || valueChanged else { continue }
            if keyChanged, index.definition.unique,
                try uniqueConflict(ctx, index: index, table: table, row: newRow, excluding: rowid) != nil
            {
                throw DBError.uniqueViolation(table: tableName, index: indexName)
            }
            changedIndexes.append((name: indexName, oldKey: oldKey, newKey: newKey, keyChanged: keyChanged))
        }

        for change in changedIndexes {
            var index = state.indexRecords[change.name]!
            var indexHandle = index.handle
            if change.keyChanged {
                let removed = try deleteBytes(ctx, &indexHandle, key: change.oldKey)
                guard removed else {
                    throw DBError.integrityFailure(
                        "index \(change.name) missing entry for \(tableName) rowid \(rowid)")
                }
            }
            // Key-stable value updates overwrite in place (BTree.put replaces on an
            // exact key match), so no delete is needed in that case.
            try putBytes(
                ctx, &indexHandle, key: change.newKey,
                value: indexEntryValue(index: index, table: table, row: newRow))
            index.handle = indexHandle
            state.indexRecords[change.name] = index
        }

        var handle = table.handle
        try putBytes(ctx, &handle, key: KeyCodec.rowKey(rowid), value: RecordCodec.encode(newRow))
        table.handle = handle
        state.tableRecords[tableName] = table
        ctx.relation = state
        // AFTER UPDATE row triggers: OLD = pre-update row, NEW = post-update row.
        try TriggerEngine.fire(ctx, event: .update, table: tableName, old: oldRow, new: newRow)
        return true
    }
}
