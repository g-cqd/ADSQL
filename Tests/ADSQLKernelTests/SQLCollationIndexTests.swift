import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// An indexed equality/IN whose comparison collation differs from the index column's
/// collation (via an explicit `COLLATE`) must NOT be silently satisfied by the index
/// seek — the seek encodes keys in the column's collation, so dropping the conjunct
/// from the residual would under-/mis-return rows. Differential vs SQLite. (Surfaced
/// by a soundness review of the covered-conjunct/residual-elimination path.)
@Suite("Indexed equality vs COLLATE override")
struct SQLCollationIndexTests {
    private func makePair(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
        let db = try Database.open(at: dir.file(name))
        let mirror = SQLiteMirror()
        for stmt in [
            "CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT)",
            "CREATE INDEX ix_a ON t(a)",
        ] {
            try db.prepare(stmt).run()
        }
        try mirror.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT); CREATE INDEX ix_a ON t(a);")
        let rows: [(Int64, String)] = [
            (1, "Apple"), (2, "apple"), (3, "APPLE"), (4, "banana"), (5, "aPPle"), (6, "Banana"),
        ]
        for (id, a) in rows {
            try db.prepare("INSERT INTO t(id, a) VALUES(?, ?)").run(.integer(id), .text(a))
            try mirror.insertRow("t", ["id", "a"], [.integer(id), .text(a)])
        }
        return (db, mirror)
    }

    /// `WHERE a = 'apple' COLLATE NOCASE` over a BINARY index: SQLite returns all
    /// case-insensitive matches; ADSQL must too (not just the BINARY-exact 'apple').
    @Test func equalityCollateOverrideMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try makePair(dir, "collate-eq.adsql")
        defer { db.close() }

        let sql = "SELECT a FROM t WHERE a = 'apple' COLLATE NOCASE ORDER BY id"
        let plan = try db.prepare(sql).planDescription()
        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(
            rowsMatch(ours, theirs, ordered: true),
            "COLLATE-override equality: ADSQL \(ours) vs SQLite \(theirs) [plan: \(plan)]")
    }

    /// `WHERE a IN ('apple','banana') COLLATE NOCASE` — same hazard on the IN path.
    @Test func inListCollateOverrideMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try makePair(dir, "collate-in.adsql")
        defer { db.close() }

        let sql = "SELECT a FROM t WHERE a COLLATE NOCASE IN ('apple', 'banana') ORDER BY id"
        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(
            rowsMatch(ours, theirs, ordered: true),
            "COLLATE-override IN: ADSQL \(ours) vs SQLite \(theirs)")
    }

    /// Control: a NOCASE-declared column with a matching index — `WHERE a = ?` uses the
    /// index correctly (collations agree), proving the gate doesn't over-reject.
    @Test func matchingCollationStillUsesIndex() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("collate-ok.adsql"))
        defer { db.close() }
        let mirror = SQLiteMirror()
        for stmt in [
            "CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT COLLATE NOCASE)",
            "CREATE INDEX ix_a ON t(a)",
        ] {
            try db.prepare(stmt).run()
        }
        try mirror.exec(
            "CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT COLLATE NOCASE); CREATE INDEX ix_a ON t(a);")
        for (id, a) in [(Int64(1), "Apple"), (2, "apple"), (3, "banana")] {
            try db.prepare("INSERT INTO t(id, a) VALUES(?, ?)").run(.integer(id), .text(a))
            try mirror.insertRow("t", ["id", "a"], [.integer(id), .text(a)])
        }
        let sql = "SELECT a FROM t WHERE a = 'APPLE' ORDER BY id"
        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, theirs, ordered: true), "NOCASE column: ADSQL \(ours) vs SQLite \(theirs)")
    }
}
