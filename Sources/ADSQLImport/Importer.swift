public import ADSQLKernel

extension Database {
    /// Imports a source SQLite `.db` into this (already-open, writable) ADSQL
    /// database — the apple-docs swap gate (M8 F1, RFC 0010). It:
    ///
    /// - auto-introspects every regular source table (`sqlite_master` +
    ///   `PRAGMA table_info`), creates it with strict, affinity-mapped columns
    ///   (preserving the `INTEGER PRIMARY KEY` rowid), and **batch-copies** its
    ///   rows, coercing each loose source cell to its strict column type, then
    ///   ports its explicit (`CREATE INDEX`) secondary indexes;
    /// - reconstructs each FTS5 table named in `manifest` from its source rows
    ///   (FTS5 config isn't introspectable, hence the manifest);
    /// - returns a **deep** integrity report.
    ///
    /// Rows are committed in batches of `batchSize` (one write transaction each)
    /// to bound dirty-page memory over a large corpus. The target **must be empty**
    /// — importing an object it already has throws, so a re-run never duplicates.
    @discardableResult
    public func importSQLite(
        from sqlitePath: String, manifest: ImportManifest = .empty, batchSize: Int = 10_000
    ) throws(DBError) -> IntegrityReport {
        let source = try SQLiteSource(path: sqlitePath)
        let skip = manifest.skipTableNames

        // Idempotency: refuse to import an object the target already has, so a
        // re-run never silently duplicates (a re-import means a fresh target).
        let existing = try read { (txn) throws(DBError) in
            let schema = try txn.schema()
            return Set(schema.tables.keys).union(schema.ftsTables.keys)
        }

        for tableName in try source.tableNames() where !skip.contains(tableName) {
            // Virtual tables (FTS5 and the like) are only imported via the manifest.
            if let sql = try source.createSQL(of: tableName),
                sql.uppercased().contains("VIRTUAL TABLE")
            {
                continue
            }
            guard !existing.contains(tableName) else {
                throw DBError.invalidDefinition("import target already contains table '\(tableName)'")
            }
            // F6: create any build-time denorm columns WITH the table (no ALTER TABLE);
            // they are populated after every table exists (see `populateDenorm`).
            let denormColumns = manifest.denorm.first { $0.table == tableName }?.columnDefinitions ?? []
            try importTable(
                named: tableName, from: source, batchSize: batchSize, denormColumns: denormColumns)
        }

        for fts in manifest.ftsTables {
            guard !existing.contains(fts.name) else {
                throw DBError.invalidDefinition("import target already contains FTS table '\(fts.name)'")
            }
            try importFTS(fts, from: source, batchSize: batchSize)
        }

        // F6: fill the denorm columns now that every source table (incl. any lookup
        // table a denorm column reads) has been imported.
        for denorm in manifest.denorm { try populateDenorm(denorm) }

        return try verifyIntegrity(deep: true)
    }

    private func importTable(
        named tableName: String, from source: SQLiteSource, batchSize: Int,
        denormColumns: [ColumnDefinition] = []
    ) throws(DBError) {
        let columns = try source.columns(of: tableName)
        let pk: PrimaryKey =
            if let alias = columns.first(where: { $0.isRowidAlias }) {
                .rowidAlias(column: alias.name, autoincrement: false)
            } else {
                .implicitRowid
            }
        // Source columns first, then any F6 denorm columns (nullable, filled post-copy).
        let definition = TableDefinition(
            tableName,
            columns: columns.map { ColumnDefinition($0.name, $0.type, notNull: $0.notNull) } + denormColumns,
            primaryKey: pk)
        try writeSync { (txn) throws(DBError) in try txn.createTable(definition) }

        // Slots cover only the SOURCE columns; the trailing denorm columns are left to
        // their default (NULL) during the copy and populated afterward.
        let slots = Array(0..<columns.count)
        var batch: [[Value]] = []
        batch.reserveCapacity(batchSize)
        func flush() throws(DBError) {
            guard !batch.isEmpty else { return }
            let rows = batch
            batch.removeAll(keepingCapacity: true)
            try writeSync { (txn) throws(DBError) in
                for values in rows {
                    try txn.insertAssembled(into: tableName, columnSlots: slots, values: values)
                }
            }
        }
        try source.forEachRow(of: tableName, columnCount: columns.count) { (cells) throws(DBError) in
            var values: [Value] = []
            values.reserveCapacity(cells.count)
            for (index, cell) in cells.enumerated() {
                values.append(cell.coerced(to: columns[index].type))
            }
            batch.append(values)
            if batch.count >= batchSize { try flush() }
        }
        try flush()

        // Port explicit secondary indexes (each backfills from the rows just copied).
        // An index whose widest key exceeds ADSQL's B-tree key limit (e.g. a long
        // `usr`) cannot be built — skip it with a warning rather than failing the whole
        // import: the table data is intact and only that secondary index is omitted.
        // Other failures (e.g. a UNIQUE violation) still propagate.
        for index in try source.indexes(of: tableName) {
            do {
                try writeSync { (txn) throws(DBError) in
                    try txn.createIndex(
                        IndexDefinition(
                            index.name, on: tableName, columns: index.columns, unique: index.unique))
                }
            } catch DBError.indexKeyTooLarge(_, let size) {
                print("import: skipped index \(index.name) on \(tableName): key \(size) B over the limit")
            }
        }
    }

    /// F6: fills the denorm columns of `denorm.table` (created empty during the copy).
    /// Per-row columns via one `UPDATE … SET name = valueSQL, …`; each lookup column via
    /// one `UPDATE` per (small) lookup-table row keyed on `matchColumn`, then a
    /// `fallbackColumn` fill for the rows with no match. Column names + value expressions
    /// come from the TRUSTED manifest (interpolated, like the FTS table/column names);
    /// the lookup-table VALUES are bound parameters. (For a very large table the single
    /// per-row UPDATE is one big write txn — fine for a one-time build; batch by rowid if
    /// that ever bites.)
    private func populateDenorm(_ denorm: ImportManifest.Denorm) throws(DBError) {
        if !denorm.columns.isEmpty {
            let assignments = denorm.columns.map { "\($0.name) = \($0.valueSQL)" }.joined(separator: ", ")
            try prepare("UPDATE \(denorm.table) SET \(assignments)").run()
        }
        for lookup in denorm.lookups {
            let lookupRows = try prepare(
                "SELECT \(lookup.lookupKey), \(lookup.lookupValue) FROM \(lookup.lookupTable)"
            ).all()
            let update = try prepare(
                "UPDATE \(denorm.table) SET \(lookup.name) = ? WHERE \(lookup.matchColumn) = ?")
            for row in lookupRows { try update.run(row[1], row[0]) }  // SET <value> WHERE … = <key>
            try prepare(
                "UPDATE \(denorm.table) SET \(lookup.name) = \(lookup.fallbackColumn) "
                    + "WHERE \(lookup.name) IS NULL"
            ).run()
        }
    }

    private func importFTS(
        _ fts: ImportManifest.FTSTable, from source: SQLiteSource, batchSize: Int
    ) throws(DBError) {
        guard fts.source.columns.count == fts.columns.count else {
            throw DBError.invalidDefinition(
                "FTS \(fts.name): \(fts.source.columns.count) source columns ≠ \(fts.columns.count) FTS columns")
        }
        try writeSync { (txn) throws(DBError) in try txn.createVirtualTable(fts.ftsDefinition) }

        var batch: [(Int64, [String])] = []
        batch.reserveCapacity(batchSize)
        func flush() throws(DBError) {
            guard !batch.isEmpty else { return }
            let docs = batch
            batch.removeAll(keepingCapacity: true)
            try writeSync { (txn) throws(DBError) in
                for (docid, texts) in docs {
                    try txn.ftsAdd(fts.name, docid: docid, columnTexts: texts)
                }
            }
        }
        try source.forEachFTSDoc(sourceTable: fts.source.table, sourceColumns: fts.source.columns) {
            (docid, texts) throws(DBError) in
            batch.append((docid, texts))
            if batch.count >= batchSize { try flush() }
        }
        try flush()
    }
}
