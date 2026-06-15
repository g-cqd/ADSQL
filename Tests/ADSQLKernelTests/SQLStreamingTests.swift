import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// F5 — streaming `Statement.forEach`. The contract pinned here: `forEach` yields
/// EXACTLY the same rows, in the same order, as `all()` — for every query shape,
/// whether it takes the bounded-memory streamed single-table path (unbounded scan
/// / filtered / rowid-ordered / DISTINCT-no-order) or the materialize-then-iterate
/// path (unordered ORDER BY, bounded top-N, LIMIT, aggregate, join, compound) — and
/// an early `false` return stops iteration immediately. The streamed path is a
/// memory optimization; the OBSERVABLE equivalence + early-exit is the contract, and
/// since `all()` is itself differentially tested vs SQLite, `forEach ≡ all()`
/// transitively pins streaming to SQLite semantics too.
@Suite("SQL streaming forEach")
struct SQLStreamingTests {
    /// `t(id PK, grp, name)` with 50 rows (some NULL names, `grp` in 0..4) + a small
    /// `g(grp_id PK, label)` for the join shape.
    private static func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("stream.adsql"))
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(
                TableDefinition(
                    "t",
                    columns: [
                        ColumnDefinition("id", .integer, notNull: true),
                        ColumnDefinition("grp", .integer),
                        ColumnDefinition("name", .text),
                    ],
                    primaryKey: .rowidAlias(column: "id", autoincrement: true)))
            try txn.createTable(
                TableDefinition(
                    "g",
                    columns: [
                        ColumnDefinition("grp_id", .integer, notNull: true),
                        ColumnDefinition("label", .text),
                    ],
                    primaryKey: .rowidAlias(column: "grp_id", autoincrement: false)))
        }
        for i in 1...50 {
            let row: [String: Value] = [
                "id": .integer(Int64(i)),
                "grp": .integer(Int64(i % 5)),
                "name": (i % 7 == 0) ? .null : .text("n\(i)"),
            ]
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "t", row) }
        }
        for k in 0..<5 {
            try db.writeSync { (txn) throws(DBError) in
                try txn.insert(into: "g", ["grp_id": .integer(Int64(k)), "label": .text("g\(k)")])
            }
        }
        return db
    }

    private func streamed(_ db: Database, _ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        var out: [[Value]] = []
        try db.prepare(sql).forEach(params) { row in
            out.append(row.values)
            return true
        }
        return out
    }

    private func materialized(_ db: Database, _ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        try db.prepare(sql).all(SQLParameters(positional: params)).map(\.values)
    }

    /// `forEach` ≡ `all()` for every shape — the streamed paths and the materialized
    /// (sort / top-N / LIMIT / aggregate / join / compound) paths alike.
    @Test func streamEqualsAllAcrossShapes() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        let queries: [(label: String, sql: String, params: [Value])] = [
            ("unbounded scan (streamed)", "SELECT id, name FROM t", []),
            ("filtered scan (streamed)", "SELECT id, name FROM t WHERE grp = ?", [.integer(2)]),
            ("rowid order (streamed)", "SELECT id FROM t ORDER BY id", []),
            ("DISTINCT no-order (streamed)", "SELECT DISTINCT grp FROM t", []),
            ("rowid point (streamed)", "SELECT id, name FROM t WHERE id = 7", []),
            ("rowid IN (streamed)", "SELECT id FROM t WHERE id IN (3, 1, 9, 50)", []),
            ("unordered ORDER BY (materialized)", "SELECT grp, id FROM t ORDER BY grp, id", []),
            ("bounded top-N (materialized)", "SELECT id, name FROM t ORDER BY name LIMIT 10", []),
            ("ordered + LIMIT (materialized)", "SELECT id FROM t WHERE grp = 1 LIMIT 3", []),
            ("scan + OFFSET/LIMIT (materialized)", "SELECT id FROM t ORDER BY id LIMIT 7 OFFSET 5", []),
            ("aggregate (materialized)", "SELECT grp, COUNT(*) FROM t GROUP BY grp ORDER BY grp", []),
            ("join (materialized)", "SELECT t.id, g.label FROM t JOIN g ON t.grp = g.grp_id ORDER BY t.id", []),
            ("compound (materialized)", "SELECT id FROM t WHERE grp = 1 UNION ALL SELECT id FROM t WHERE grp = 2", []),
        ]
        for (label, sql, params) in queries {
            let s = try streamed(db, sql, params)
            let a = try materialized(db, sql, params)
            #expect(s == a, "\(label): forEach \(s.count) rows != all() \(a.count) rows — \(sql)")
        }
    }

    /// Returning `false` stops iteration; rows seen so far are exactly the prefix.
    @Test func earlyExitStopsAfterPrefix() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        var seen: [Int64] = []
        try db.prepare("SELECT id FROM t ORDER BY id").forEach { row in
            if case .integer(let v) = row.values[0] { seen.append(v) }
            return seen.count < 5
        }
        #expect(seen == [1, 2, 3, 4, 5])
    }

    /// Early-exit on the first row of an unbounded scan invokes the body exactly once.
    @Test func earlyExitOnFirstRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        var count = 0
        try db.prepare("SELECT id, name FROM t").forEach { _ in
            count += 1
            return false
        }
        #expect(count == 1)
    }

    /// A body that always returns true visits every row exactly once (no early stop).
    @Test func fullScanVisitsEveryRowOnce() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        var count = 0
        try db.prepare("SELECT id FROM t").forEach { _ in
            count += 1
            return true
        }
        #expect(count == 50)
    }

    /// `forEach` on a non-row statement throws (mirrors `all()` on a write).
    @Test func forEachOnNonSelectThrows() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        var threw = false
        do {
            try db.prepare("INSERT INTO t(id, grp, name) VALUES (999, 9, 'x')").forEach { _ in true }
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
