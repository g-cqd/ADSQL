import ADSQL
import CSQLite
import Darwin
import Foundation

/// Relational benchmark on the literal apple-docs `documents` shape:
/// rowid-alias PK + 5 secondary indexes (one unique, one NOCASE, one
/// composite), batch inserts with full index maintenance, rowid gets,
/// unique-key probes, and an index range scan.
enum TableScenario {
    static let frameworks = ["swiftui", "foundation", "uikit", "appkit", "metal", "swift"]
    static let kinds = ["symbol", "article", "collection", "sample"]

    static func run(_ engine: String, dir: String, config: BenchConfig) throws {
        let rows = min(config.rows, 200_000)
        let path = "\(dir)/table-\(engine).db"
        unlink(path)
        unlink(path + "-wal")
        unlink(path + "-shm")
        unlink(path + "-lock")

        if engine == "adsql" {
            try runADSQL(path: path, rows: rows, config: config)
        } else {
            try runSQLite(path: path, rows: rows, config: config)
        }
    }

    // MARK: - ADSQL

    static func runADSQL(path: String, rows: Int, config: BenchConfig) throws {
        let db = try Database.open(
            at: path, options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(
                TableDefinition(
                    "documents",
                    columns: [
                        ColumnDefinition("id", .integer, notNull: true),
                        ColumnDefinition("key", .text, notNull: true),
                        ColumnDefinition("title", .text, notNull: true, collation: .nocase),
                        ColumnDefinition("framework", .text),
                        ColumnDefinition("kind", .text),
                        ColumnDefinition("is_deprecated", .integer, defaultValue: .value(.integer(0))),
                    ],
                    primaryKey: .rowidAlias(column: "id", autoincrement: true)))
            try txn.createIndex(IndexDefinition("u_documents_key", on: "documents", columns: ["key"], unique: true))
            try txn.createIndex(
                IndexDefinition("i_documents_framework", on: "documents", columns: ["framework"], includes: ["kind"]))
            try txn.createIndex(IndexDefinition("i_documents_kind", on: "documents", columns: ["kind"]))
            try txn.createIndex(IndexDefinition("i_documents_title", on: "documents", columns: ["title"]))
            try txn.createIndex(
                IndexDefinition("i_documents_fw_kind", on: "documents", columns: ["framework", "kind"]))
        }

        // Batched inserts with 5-index maintenance.
        let insertStart = nowNanos()
        var inserted = 0
        while inserted < rows {
            let batchEnd = min(inserted + 512, rows)
            let lower = inserted
            try db.writeSync { (txn) throws(DBError) in
                for i in lower..<batchEnd {
                    _ = try txn.insert(
                        into: "documents",
                        [
                            "key": .text("documentation/fw\(i % 6)/symbol-\(i)"),
                            "title": .text("Symbol \(i) Overview"),
                            "framework": .text(frameworks[i % frameworks.count]),
                            "kind": .text(kinds[i % kinds.count]),
                        ])
                }
            }
            inserted = batchEnd
        }
        let insertElapsed = nowNanos() - insertStart
        print("  [adsql] table insert    \(formatRate(rows, insertElapsed)) rows/s (5 indexes)")

        // Rowid point gets.
        var rng = BenchRNG(seed: 17)
        var rowidHist = LatencyHistogram()
        rowidHist.reserve(config.pointGets)
        for _ in 0..<config.pointGets {
            let target = Int64(rng.next() % UInt64(rows)) + 1
            let start = nowNanos()
            let row = try db.read { (txn) throws(DBError) in
                try txn.row(in: "documents", rowid: target)
            }
            rowidHist.record(nowNanos() - start)
            precondition(row != nil)
        }
        print("  [adsql] rowid get       \(rowidHist.summary())")

        // Unique-key probes.
        var probeHist = LatencyHistogram()
        probeHist.reserve(config.pointGets)
        for _ in 0..<config.pointGets {
            let i = Int(rng.next() % UInt64(rows))
            let key = Value.text("documentation/fw\(i % 6)/symbol-\(i)")
            let start = nowNanos()
            let rowid = try db.read { (txn) throws(DBError) in
                try txn.firstRowid(index: "u_documents_key", equals: [key])
            }
            probeHist.record(nowNanos() - start)
            precondition(rowid != nil)
        }
        print("  [adsql] key probe       \(probeHist.summary())")

        // Index range scan: one framework's documents.
        let scanStart = nowNanos()
        let scanned = try db.read { (txn) throws(DBError) in
            try txn.withIndexCursor(
                index: "i_documents_framework", bounds: .prefix([.text("swiftui")]),
                covering: ["kind"]
            ) { (cursor) throws(DBError) in
                var n = 0
                // columns: id,key,title,framework,kind,is_deprecated → kind = index 4.
                // Index-only scan (kind is an INCLUDE column): zero-copy presence check,
                // no table descent — matching SQLite's covering-index path.
                let kindColumn = 4
                try cursor.forEachRow { (row) throws(DBError) in
                    n += try row.withText(at: kindColumn) { $0 == nil ? 0 : 1 }
                    return true
                }
                return n
            }
        }
        let scanElapsed = nowNanos() - scanStart
        print(
            "  [adsql] index scan      \(scanned) rows in \(scanElapsed / 1_000_000) ms (\(formatRate(scanned, scanElapsed)))"
        )
    }

    // MARK: - SQLite

    static func runSQLite(path: String, rows: Int, config: BenchConfig) throws {
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else { throw SQLiteError.code(1, "open") }
        let db = handle
        defer { sqlite3_close_v2(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.code(sqlite3_errcode(db), sql)
            }
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=OFF")
        try exec("PRAGMA cache_size=-64000")
        try exec("PRAGMA mmap_size=10737418240")
        try exec(
            """
            CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              key TEXT NOT NULL, title TEXT NOT NULL COLLATE NOCASE,
              framework TEXT, kind TEXT, is_deprecated INTEGER DEFAULT 0)
            """)
        try exec("CREATE UNIQUE INDEX u_documents_key ON documents(key)")
        try exec("CREATE INDEX i_documents_framework ON documents(framework)")
        try exec("CREATE INDEX i_documents_kind ON documents(kind)")
        try exec("CREATE INDEX i_documents_title ON documents(title)")
        try exec("CREATE INDEX i_documents_fw_kind ON documents(framework, kind)")

        var insert: OpaquePointer?
        sqlite3_prepare_v3(
            db,
            "INSERT INTO documents (key, title, framework, kind) VALUES (?1, ?2, ?3, ?4)",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &insert, nil)
        defer { sqlite3_finalize(insert) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let insertStart = nowNanos()
        var inserted = 0
        while inserted < rows {
            let batchEnd = min(inserted + 512, rows)
            try exec("BEGIN IMMEDIATE")
            for i in inserted..<batchEnd {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, "documentation/fw\(i % 6)/symbol-\(i)", -1, transient)
                sqlite3_bind_text(insert, 2, "Symbol \(i) Overview", -1, transient)
                sqlite3_bind_text(insert, 3, frameworks[i % frameworks.count], -1, transient)
                sqlite3_bind_text(insert, 4, kinds[i % kinds.count], -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw SQLiteError.code(sqlite3_errcode(db), "insert")
                }
            }
            try exec("COMMIT")
            inserted = batchEnd
        }
        let insertElapsed = nowNanos() - insertStart
        print("  [sqlite] table insert    \(formatRate(rows, insertElapsed)) rows/s (5 indexes)")

        var byRowid: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT key, title, framework, kind FROM documents WHERE id = ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &byRowid, nil)
        defer { sqlite3_finalize(byRowid) }
        var rng = BenchRNG(seed: 17)
        var rowidHist = LatencyHistogram()
        rowidHist.reserve(config.pointGets)
        for _ in 0..<config.pointGets {
            let target = Int64(rng.next() % UInt64(rows)) + 1
            let start = nowNanos()
            sqlite3_reset(byRowid)
            sqlite3_bind_int64(byRowid, 1, target)
            precondition(sqlite3_step(byRowid) == SQLITE_ROW)
            rowidHist.record(nowNanos() - start)
        }
        print("  [sqlite] rowid get       \(rowidHist.summary())")

        var byKey: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT id FROM documents WHERE key = ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &byKey, nil)
        defer { sqlite3_finalize(byKey) }
        var probeHist = LatencyHistogram()
        probeHist.reserve(config.pointGets)
        for _ in 0..<config.pointGets {
            let i = Int(rng.next() % UInt64(rows))
            let start = nowNanos()
            sqlite3_reset(byKey)
            sqlite3_bind_text(byKey, 1, "documentation/fw\(i % 6)/symbol-\(i)", -1, transient)
            precondition(sqlite3_step(byKey) == SQLITE_ROW)
            probeHist.record(nowNanos() - start)
        }
        print("  [sqlite] key probe       \(probeHist.summary())")

        var scan: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT id, key, title, kind FROM documents WHERE framework = ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &scan, nil)
        defer { sqlite3_finalize(scan) }
        let scanStart = nowNanos()
        sqlite3_bind_text(scan, 1, "swiftui", -1, transient)
        var scanned = 0
        while sqlite3_step(scan) == SQLITE_ROW {
            scanned += sqlite3_column_bytes(scan, 3) > 0 ? 1 : 0
        }
        let scanElapsed = nowNanos() - scanStart
        print(
            "  [sqlite] index scan      \(scanned) rows in \(scanElapsed / 1_000_000) ms (\(formatRate(scanned, scanElapsed)))"
        )
    }
}
