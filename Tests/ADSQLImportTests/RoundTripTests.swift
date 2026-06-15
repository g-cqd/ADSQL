import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// End-to-end: build a small SQLite `.db` in the apple-docs shape (a `documents`
/// table + a self-contained `documents_fts` FTS5 table), import it, and assert the
/// imported ADSQL database matches the source — every regular row round-trips, and
/// an FTS `MATCH` returns the same docids in the same order as the source SQLite
/// FTS5 (the parity that gates the swap).
@Suite("SQLite import round-trip")
struct ImportRoundTripTests {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @Test func portsTablesAndReconstructsFTS() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let sourcePath = dir.file("source.db")
        let targetPath = dir.file("out.adsql")

        // 1. Build the SQLite fixture.
        var source: OpaquePointer?
        try #require(
            sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK)
        defer { sqlite3_close_v2(source) }
        for sql in [
            """
            CREATE TABLE documents(
              id INTEGER PRIMARY KEY, title TEXT NOT NULL, abstract TEXT,
              framework TEXT, is_deprecated INTEGER DEFAULT 0)
            """,
            """
            INSERT INTO documents(id, title, abstract, framework) VALUES
              (1, 'Swift Concurrency', 'async await tasks', 'Swift'),
              (2, 'UIKit View', 'views and layout', 'UIKit'),
              (3, 'Combine Publisher', 'reactive swift streams', 'Combine')
            """,
            "CREATE VIRTUAL TABLE documents_fts USING fts5(title, abstract, tokenize='porter unicode61')",
            "INSERT INTO documents_fts(rowid, title, abstract) SELECT id, title, abstract FROM documents",
        ] {
            try #require(sqlite3_exec(source, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
        }

        // 2. Import (the manifest reconstructs documents_fts from documents.[title,abstract]).
        let manifest = ImportManifest(ftsTables: [
            .init(
                name: "documents_fts", columns: ["title", "abstract"],
                tokenize: ["porter", "unicode61"],
                source: .init(table: "documents", columns: ["title", "abstract"]))
        ])
        let db = try Database.open(at: targetPath)
        defer { db.close() }
        _ = try db.importSQLite(from: sourcePath, manifest: manifest)

        // 3a. Every regular row round-trips (rowid preserved, values coerced strict).
        let rows = try db.prepare(
            "SELECT id, title, framework, is_deprecated FROM documents ORDER BY id"
        ).all().map(\.values)
        #expect(
            rows == [
                [.integer(1), .text("Swift Concurrency"), .text("Swift"), .integer(0)],
                [.integer(2), .text("UIKit View"), .text("UIKit"), .integer(0)],
                [.integer(3), .text("Combine Publisher"), .text("Combine"), .integer(0)],
            ])

        // 3b. FTS MATCH on the imported table ≡ the source SQLite FTS5 (docids + order).
        for term in ["swift", "views", "reactive", "layout"] {
            let ours = try db.prepare(
                "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rowid"
            ).all(.text(term)).map { $0[0] }
            let theirs = sqliteMatch(source, term).map { Value.integer($0) }
            #expect(ours == theirs, "MATCH '\(term)': adsql \(ours) vs sqlite \(theirs)")
        }
    }

    /// The source SQLite FTS5 oracle: docids matching `term`, rowid-ordered.
    private func sqliteMatch(_ db: OpaquePointer?, _ term: String) -> [Int64] {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rowid", -1,
                &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, term, -1, transient)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }
}
