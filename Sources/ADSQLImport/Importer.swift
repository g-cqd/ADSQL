public import ADSQLKernel

extension Database {
    /// Imports a source SQLite `.db` into this (already-open, writable) ADSQL
    /// database — the apple-docs swap gate (M8 F1, RFC 0010). It:
    ///
    /// - auto-introspects every regular source table (`sqlite_master` +
    ///   `PRAGMA table_info`), creates it with strict, affinity-mapped columns
    ///   (preserving the `INTEGER PRIMARY KEY` rowid), and **batch-copies** its
    ///   rows, coercing each loose source cell to its strict column type;
    /// - reconstructs each FTS5 table named in `manifest` from its source rows
    ///   (FTS5 config isn't introspectable, hence the manifest);
    /// - returns a **deep** integrity report.
    ///
    /// Rows are committed in batches of `batchSize` (one write transaction each)
    /// to bound dirty-page memory over a large corpus. The target should be empty.
    @discardableResult
    public func importSQLite(
        from sqlitePath: String, manifest: ImportManifest = .empty, batchSize: Int = 10_000
    ) throws(DBError) -> IntegrityReport {
        let source = try SQLiteSource(path: sqlitePath)
        let skip = manifest.skipTableNames

        for tableName in try source.tableNames() where !skip.contains(tableName) {
            // Virtual tables (FTS5 and the like) are only imported via the manifest.
            if let sql = try source.createSQL(of: tableName),
                sql.uppercased().contains("VIRTUAL TABLE")
            {
                continue
            }
            try importTable(named: tableName, from: source, batchSize: batchSize)
        }

        for fts in manifest.ftsTables {
            try importFTS(fts, from: source, batchSize: batchSize)
        }

        return try verifyIntegrity(deep: true)
    }

    private func importTable(
        named tableName: String, from source: SQLiteSource, batchSize: Int
    ) throws(DBError) {
        let columns = try source.columns(of: tableName)
        let pk: PrimaryKey =
            if let alias = columns.first(where: { $0.isRowidAlias }) {
                .rowidAlias(column: alias.name, autoincrement: false)
            } else {
                .implicitRowid
            }
        let definition = TableDefinition(
            tableName,
            columns: columns.map { ColumnDefinition($0.name, $0.type, notNull: $0.notNull) },
            primaryKey: pk)
        try writeSync { (txn) throws(DBError) in try txn.createTable(definition) }

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
