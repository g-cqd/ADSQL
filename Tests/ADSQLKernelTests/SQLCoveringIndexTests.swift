import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// F4 — COVERING / INCLUDE-index serving. A SELECT whose every still-needed
/// base-table column lives in the chosen index's served set (the rowid-alias,
/// read from the key, plus the INCLUDE columns, read from the entry value) is
/// answered straight off the index cursor with NO descent into the base row.
///
/// These tests pin BOTH halves of the contract:
///   • POSITIVE — when a query is covered, the engine takes the index-only path
///     (the plan says COVERING) AND returns rows identical to SQLite and to the
///     same query run before the index existed (the planner-invariance oracle).
///   • NEGATIVE — when a query needs a column the index does NOT serve (a
///     non-indexed column, or a KEY column whose value is not in the entry
///     value), the engine must fall back to a table descent and still return the
///     correct rows — never serve garbage from an index-only span.
///
/// `CREATE INDEX` has no INCLUDE grammar yet, so indexes are created through the
/// `txn.createIndex(IndexDefinition(…, includes:))` API; everything else is
/// ordinary SQL run through `Database.prepare`.
@Suite("SQL covering / INCLUDE-index serving")
struct SQLCoveringIndexTests {
    /// `cov(id PK, a, b, c, d, e)` with a composite key `(a, b)` covering `(c, d)`.
    /// `a`/`b` are KEY columns (not stored in the entry value); `c`/`d` are INCLUDE
    /// columns (stored in the value); `e` is indexed by nothing. Ties on `a` (and on
    /// `(a,b)`) are seeded so the multi-row / equal-key cases are exercised.
    private enum Fixture {
        static let columns = ["id", "a", "b", "c", "d", "e"]

        static let definition = TableDefinition(
            "cov",
            columns: [
                ColumnDefinition("id", .integer, notNull: true),
                ColumnDefinition("a", .integer),
                ColumnDefinition("b", .text),
                ColumnDefinition("c", .text),
                ColumnDefinition("d", .integer),
                ColumnDefinition("e", .text),
            ],
            primaryKey: .rowidAlias(column: "id", autoincrement: true))

        /// The covering index: key `(a, b)`, INCLUDE `(c, d)`.
        static let coveringIndex =
            IndexDefinition("ix_ab_cd", on: "cov", columns: ["a", "b"], unique: false, includes: ["c", "d"])

        static let sqliteDDL = """
            CREATE TABLE cov(
              id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c TEXT, d INTEGER, e TEXT);
            CREATE INDEX ix_ab ON cov(a, b);
            """

        static func rows() -> [[Value]] {
            var rows: [[Value]] = []
            // 5 distinct `a` buckets, each with several rows; some share `(a, b)` so an
            // equality probe on `a` returns multiple rows including exact-key ties.
            for i in 1...40 {
                let a = Int64(i % 5)  // 0..4
                let b = "b\(i % 3)"  // ties within an `a` bucket
                let c: Value = (i % 7 == 0) ? .null : .text("c\(i)")
                let d: Value = (i % 6 == 0) ? .null : .integer(Int64(i * 10))
                let e = "e\(i)"
                rows.append([
                    .integer(Int64(i)), .integer(a), .text(b), c, d, .text(e),
                ])
            }
            return rows
        }

        /// Opens an ADSQL database (optionally with the covering index) populated
        /// identically to a fresh SQLite mirror.
        static func make(
            _ dir: TempDir, _ name: String, withCoveringIndex: Bool
        ) throws -> (Database, SQLiteMirror) {
            let db = try Database.open(at: dir.file(name))
            try db.writeSync { (txn) throws(DBError) in
                try txn.createTable(definition)
                if withCoveringIndex { try txn.createIndex(coveringIndex) }
            }
            let mirror = SQLiteMirror()
            try mirror.exec(sqliteDDL)
            for row in rows() {
                let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
                try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "cov", dict) }
                try mirror.insertRow("cov", columns, row)
            }
            return (db, mirror)
        }

        /// An ADSQL database with NO secondary index — the planner-invariance oracle.
        /// Any query run here uses a full table scan, so its result is the
        /// index-agnostic ground truth a covering scan must reproduce byte-for-byte.
        static func makeScanOnly(_ dir: TempDir, _ name: String) throws -> Database {
            let db = try Database.open(at: dir.file(name))
            try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
            for row in rows() {
                let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
                try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "cov", dict) }
            }
            return db
        }
    }

    // MARK: - Positive: covered query is served index-only and correctly

    /// `SELECT c, d FROM cov WHERE a = ?` — needed columns are `{c, d}` (the `a=?`
    /// equality is enforced by the index position, so `a` is never read from a row),
    /// all served by INCLUDE → the plan is COVERING and the rows match both oracles.
    /// `a = 2` returns multiple rows (a tie/multi-row case).
    @Test func coveredProjectionIsIndexOnlyAndCorrect() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Fixture.make(dir, "cov-pos.adsql", withCoveringIndex: true)
        let scan = try Fixture.makeScanOnly(dir, "cov-scan.adsql")
        defer {
            db.close()
            scan.close()
        }

        let sql = "SELECT c, d FROM cov WHERE a = ? ORDER BY d, c"

        // The planner must pick the index-only path.
        let plan = try db.prepare(sql).planDescription()
        #expect(plan.contains("USING INDEX ix_ab_cd"), "expected the covering index, got: \(plan)")
        #expect(plan.contains("COVERING"), "expected an index-only (COVERING) scan, got: \(plan)")

        for a in [Value.integer(2), .integer(0), .integer(4)] {
            let ours = try db.prepare(sql).all(a).map(\.values)
            let scanRows = try scan.prepare(sql).all(a).map(\.values)
            let theirs = try mirror.query(sql, [a])
            #expect(ours.count >= 2 || a != .integer(2), "a=2 must be a multi-row case")
            #expect(rowsMatch(ours, scanRows, ordered: true), "a=\(a): covering \(ours) vs scan \(scanRows)")
            #expect(rowsMatch(ours, theirs, ordered: true), "a=\(a): covering \(ours) vs sqlite \(theirs)")
        }
    }

    /// A covered query that also returns the rowid-alias (`id`, served from the key)
    /// and an INCLUDE column, with a range on the trailing key column kept as a
    /// residual — the residual reads only covered columns, so it stays index-only.
    @Test func coveredWithRowidAndResidualIsIndexOnly() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Fixture.make(dir, "cov-rowid.adsql", withCoveringIndex: true)
        let scan = try Fixture.makeScanOnly(dir, "cov-rowid-scan.adsql")
        defer {
            db.close()
            scan.close()
        }

        // `id` (rowid-alias, from the key) + `c` (INCLUDE). `b > 'b0'` is a trailing
        // range on a key column, kept as a residual — but `b` is never read: the range
        // is enforced by the key bytes the cursor scans, and `b` is not projected. So
        // the required set stays `{id, c}` ⊆ servable and the scan is index-only.
        let sql = "SELECT id, c FROM cov WHERE a = 1 ORDER BY id"
        let plan = try db.prepare(sql).planDescription()
        #expect(plan.contains("COVERING"), "expected index-only, got: \(plan)")

        let ours = try db.prepare(sql).all().map(\.values)
        let scanRows = try scan.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, scanRows, ordered: true))
        #expect(rowsMatch(ours, theirs, ordered: true))
    }

    // MARK: - Negative: uncovered query falls back to a descent and stays correct

    /// `SELECT e …` — `e` is in NO index, so it must be read from the base row. The
    /// scan must NOT be index-only (no COVERING), and the rows must still be correct
    /// (a regression guard: an over-eager covering claim here would serve garbage,
    /// since `e` is not in the entry value).
    @Test func uncoveredColumnInProjectionFallsBackAndStaysCorrect() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Fixture.make(dir, "cov-neg-proj.adsql", withCoveringIndex: true)
        let scan = try Fixture.makeScanOnly(dir, "cov-neg-proj-scan.adsql")
        defer {
            db.close()
            scan.close()
        }

        let sql = "SELECT c, e FROM cov WHERE a = 3 ORDER BY id"
        let plan = try db.prepare(sql).planDescription()
        #expect(!plan.contains("COVERING"), "e is not covered; must descend, got: \(plan)")

        let ours = try db.prepare(sql).all().map(\.values)
        let scanRows = try scan.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, scanRows, ordered: true), "covering-fallback \(ours) vs scan \(scanRows)")
        #expect(rowsMatch(ours, theirs, ordered: true), "covering-fallback \(ours) vs sqlite \(theirs)")
    }

    /// `WHERE e = ?` — `e` is referenced by a residual predicate (it is not an
    /// index-covered conjunct), so it must be read from the base row → not covering,
    /// and still correct.
    @Test func uncoveredColumnInWhereFallsBackAndStaysCorrect() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Fixture.make(dir, "cov-neg-where.adsql", withCoveringIndex: true)
        let scan = try Fixture.makeScanOnly(dir, "cov-neg-where-scan.adsql")
        defer {
            db.close()
            scan.close()
        }

        // `a = 2` would pick the index, but `e = 'e12'` in the residual reads `e`.
        let sql = "SELECT c FROM cov WHERE a = 2 AND e = ? ORDER BY c"
        let plan = try db.prepare(sql).planDescription()
        #expect(!plan.contains("COVERING"), "e read by residual; must descend, got: \(plan)")

        let param = Value.text("e12")
        let ours = try db.prepare(sql).all(param).map(\.values)
        let scanRows = try scan.prepare(sql).all(param).map(\.values)
        let theirs = try mirror.query(sql, [param])
        #expect(rowsMatch(ours, scanRows, ordered: true))
        #expect(rowsMatch(ours, theirs, ordered: true))
    }

    /// `SELECT b …` — `b` is a KEY column but NOT the rowid-alias and NOT an INCLUDE,
    /// so its value is not in the entry value and the index cannot serve it
    /// index-only. The CORRECT (conservative) rule rejects covering here even though
    /// `b ∈ key ∪ includes`; the engine must descend and return correct rows. This
    /// pins the stricter-than-`key ∪ includes` rule the storage layout requires.
    @Test func keyColumnNotServedIndexOnly() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Fixture.make(dir, "cov-neg-key.adsql", withCoveringIndex: true)
        let scan = try Fixture.makeScanOnly(dir, "cov-neg-key-scan.adsql")
        defer {
            db.close()
            scan.close()
        }

        let sql = "SELECT b, c FROM cov WHERE a = 4 ORDER BY id"
        let plan = try db.prepare(sql).planDescription()
        #expect(
            !plan.contains("COVERING"),
            "b is a key column, not in the entry value; must descend, got: \(plan)")

        let ours = try db.prepare(sql).all().map(\.values)
        let scanRows = try scan.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, scanRows, ordered: true))
        #expect(rowsMatch(ours, theirs, ordered: true))
    }

    /// Adversarial layout: INCLUDE order `(d, c)` is the REVERSE of schema order
    /// `(c, d)`. The index-only decoder must map each schema column to its slot
    /// WITHIN the entry value (`d` at slot 0, `c` at slot 1), not by schema position
    /// — a decoder that assumed schema order would return `c` where `d` is asked and
    /// vice-versa. Comparing to the scan/SQLite oracles catches exactly that.
    @Test func includeOrderDiffersFromSchemaOrder() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("cov-reorder.adsql"))
        let scan = try Fixture.makeScanOnly(dir, "cov-reorder-scan.adsql")
        defer {
            db.close()
            scan.close()
        }
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(Fixture.definition)
            // INCLUDE (d, c) — reversed relative to the schema's (c, d).
            try txn.createIndex(
                IndexDefinition("ix_dc", on: "cov", columns: ["a", "b"], includes: ["d", "c"]))
        }
        let mirror = SQLiteMirror()
        try mirror.exec(Fixture.sqliteDDL)
        for row in Fixture.rows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(Fixture.columns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "cov", dict) }
            try mirror.insertRow("cov", Fixture.columns, row)
        }

        // Project `c` and `d` in schema order; the value layout is the opposite.
        let sql = "SELECT c, d FROM cov WHERE a = 2 ORDER BY id"
        let plan = try db.prepare(sql).planDescription()
        #expect(plan.contains("COVERING"), "expected index-only, got: \(plan)")

        let ours = try db.prepare(sql).all().map(\.values)
        let scanRows = try scan.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, scanRows, ordered: true), "reordered-INCLUDE \(ours) vs scan \(scanRows)")
        #expect(rowsMatch(ours, theirs, ordered: true), "reordered-INCLUDE \(ours) vs sqlite \(theirs)")
    }

    // MARK: - Direct binder assertion (the covering decision, isolated)

    /// Inspects the bound plan directly so the covering *decision* is pinned
    /// independent of execution: a covered projection carries `covering = includes`;
    /// an uncovered one carries `nil`.
    @Test func boundPlanCarriesCoveringDecision() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, _) = try Fixture.make(dir, "cov-bind.adsql", withCoveringIndex: true)
        defer { db.close() }

        func covering(_ sql: String) throws -> [String]? {
            try db.read { (txn) throws(DBError) in
                guard case .select(let select) = try SQLParser.parseOne(sql),
                    case .select(let plan) = try Binder.bindQuery(select, schema: try txn.schema()),
                    case .index(_, _, _, let covering) = plan.access
                else { return nil }
                return covering
            }
        }

        // Covered: every needed column is the rowid-alias or an INCLUDE.
        #expect(try covering("SELECT c, d FROM cov WHERE a = 5") == ["c", "d"])
        #expect(try covering("SELECT d FROM cov WHERE a = 5 AND b = 'b0'") == ["c", "d"])
        #expect(try covering("SELECT id, c FROM cov WHERE a = 5") == ["c", "d"])
        // Uncovered: `e` (no index), `b` (key column, not in the entry value), or the
        // probe chose no index at all.
        #expect(try covering("SELECT e FROM cov WHERE a = 5") == nil)
        #expect(try covering("SELECT b FROM cov WHERE a = 5") == nil)
        #expect(try covering("SELECT c FROM cov WHERE e = 'e1'") == nil)
    }
}
