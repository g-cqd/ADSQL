import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// Follow-on robustness for the importer (M8 F1): explicit-index port, the
/// empty-target idempotency guard, and import determinism.
@Suite("SQLite import — follow-on")
struct ImportFollowOnTests {
    private var manifest: ImportManifest {
        ImportManifest(ftsTables: [
            .init(
                name: "documents_fts", columns: ["title"], tokenize: ["porter", "unicode61"],
                source: .init(table: "documents", columns: ["title"]))
        ])
    }

    /// A `documents` table (with a `CREATE INDEX`) + a self-contained FTS5 table.
    private func makeFixture(at path: String) throws {
        var db: OpaquePointer?
        try #require(
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        for sql in [
            "CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT NOT NULL, framework TEXT)",
            "CREATE INDEX idx_framework ON documents(framework)",
            """
            INSERT INTO documents VALUES
              (1, 'Swift Concurrency', 'Swift'), (2, 'UIKit View', 'UIKit'),
              (3, 'Reactive Swift', 'Combine')
            """,
            "CREATE VIRTUAL TABLE documents_fts USING fts5(title, tokenize='porter unicode61')",
            "INSERT INTO documents_fts(rowid, title) SELECT id, title FROM documents",
        ] {
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
        }
    }

    @Test func portsExplicitIndexes() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("source.db")
        try makeFixture(at: source)

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: source, manifest: manifest)

        let indexes = try db.read { (txn) throws(DBError) in try txn.schema().indexes(on: "documents") }
        #expect(indexes.contains { $0.name == "idx_framework" && $0.columns == ["framework"] })
    }

    @Test func refusesReimportIntoNonEmptyTarget() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("source.db")
        try makeFixture(at: source)

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: source, manifest: manifest)

        // A second import into the now-populated target must refuse (no silent dup).
        var threw = false
        do { _ = try db.importSQLite(from: source, manifest: manifest) } catch { threw = true }
        #expect(threw)
        // The first import's data is intact.
        #expect(try db.read { (txn) throws(DBError) in try txn.rowCount(in: "documents") } == 3)
    }

    @Test func importIsDeterministic() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("source.db")
        try makeFixture(at: source)

        func importedRowsAndMatches(_ name: String) throws -> ([[Value]], [[Value]]) {
            let db = try Database.open(at: dir.file(name))
            defer { db.close() }
            _ = try db.importSQLite(from: source, manifest: manifest)
            let rows = try db.prepare("SELECT id, title, framework FROM documents ORDER BY id").all()
                .map(\.values)
            var matches: [[Value]] = []
            for term in ["swift", "view", "reactive"] {
                matches.append(
                    try db.prepare(
                        "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rowid"
                    ).all(.text(term)).map { $0[0] })
            }
            return (rows, matches)
        }

        let (rows1, matches1) = try importedRowsAndMatches("a.adsql")
        let (rows2, matches2) = try importedRowsAndMatches("b.adsql")
        #expect(rows1 == rows2)
        #expect(matches1 == matches2)
    }

    @Test func portsPrimaryKeyAndUniqueConstraints() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("roots.db")
        var src: OpaquePointer?
        try #require(
            sqlite3_open_v2(source, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(src) }
        for sql in [
            "CREATE TABLE roots(slug TEXT PRIMARY KEY, display_name TEXT, code TEXT UNIQUE)",
            "INSERT INTO roots VALUES ('uikit', 'UIKit', 'UK'), ('swiftui', 'SwiftUI', 'SU')",
        ] {
            try #require(sqlite3_exec(src, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
        }

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: source)  // no FTS → no manifest needed

        // The TEXT PRIMARY KEY (slug, not a rowid alias) + the UNIQUE column (code)
        // port as unique indexes — the slug index is the roots-join key.
        let indexes = try db.read { (txn) throws(DBError) in try txn.schema().indexes(on: "roots") }
        #expect(indexes.contains { $0.columns == ["slug"] && $0.unique })
        #expect(indexes.contains { $0.columns == ["code"] && $0.unique })
        #expect(try db.read { (txn) throws(DBError) in try txn.rowCount(in: "roots") } == 2)
    }

    /// The explicit `skipTables` manifest field skips a regular table; and an index
    /// whose widest key exceeds ADSQL's B-tree limit is skipped (with a warning)
    /// rather than failing the whole import — the table data stays intact. (Surfaced
    /// by the real apple-docs corpus: `idx_documents_usr` keys exceed 1024 bytes.)
    @Test func skipsTablesAndOverLongKeyIndexes() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("src.db")
        var src: OpaquePointer?
        try #require(
            sqlite3_open_v2(source, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(src) }
        let longLabel = String(repeating: "x", count: 2000)  // index key > 1024 bytes
        for sql in [
            "CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT)",
            "CREATE INDEX idx_label ON docs(label)",
            "CREATE TABLE junk(id INTEGER PRIMARY KEY, x TEXT)",
            "INSERT INTO docs VALUES (1, '\(longLabel)'), (2, 'short')",
            "INSERT INTO junk VALUES (1, 'a')",
        ] {
            try #require(sqlite3_exec(src, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
        }

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        // Must NOT throw: `junk` is skipped via the manifest; `idx_label` (over-long
        // key) is skipped gracefully, not fatal.
        _ = try db.importSQLite(from: source, manifest: ImportManifest(skipTables: ["junk"]))

        #expect(try db.read { (txn) throws(DBError) in try txn.rowCount(in: "docs") } == 2)
        let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
        #expect(!schema.tables.keys.contains("junk"), "skipTables should skip 'junk'")
        let indexes = try db.read { (txn) throws(DBError) in try txn.schema().indexes(on: "docs") }
        #expect(!indexes.contains { $0.name == "idx_label" }, "over-long-key index must be skipped")
    }
}
