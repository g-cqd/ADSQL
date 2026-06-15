import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// Coverage: `SELECT DISTINCT` routed through the JOIN and AGGREGATE execution
/// paths — i.e. the post-scan `deduplicate` pass (`ResultPipeline`). The
/// single-table path streams DISTINCT inline (`streamedDistinct`), so its
/// post-scan dedup branch is dead; the join/aggregate paths instead collect rows
/// then dedup, and that pass had no test. Each query produces duplicate rows
/// BEFORE `DISTINCT` so the dedup does real work, validated against SQLite (the
/// oracle), covering both the unordered (`ordered: false`) and ORDER-BY
/// (`ordered: true`, sort-key-aligned) dedup branches.
@Suite("SQL DISTINCT over join / aggregate")
struct SQLDistinctComposedTests {
    /// `emp(id, dept, city)` × 30 with `dept` ∈ {1,2} and `city` ∈ {NYC,LA,SF}
    /// cross-cutting (each city spans both depts) so DISTINCT collapses real
    /// duplicates; `dept(dept_id, name)` × 2 for the join.
    private static func make(_ dir: TempDir) throws -> (Database, SQLiteMirror) {
        let db = try Database.open(at: dir.file("distinct.adsql"))
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(
                TableDefinition(
                    "emp",
                    columns: [
                        ColumnDefinition("id", .integer, notNull: true),
                        ColumnDefinition("dept", .integer),
                        ColumnDefinition("city", .text),
                    ],
                    primaryKey: .rowidAlias(column: "id", autoincrement: true)))
            try txn.createTable(
                TableDefinition(
                    "dept",
                    columns: [
                        ColumnDefinition("dept_id", .integer, notNull: true),
                        ColumnDefinition("name", .text),
                    ],
                    primaryKey: .rowidAlias(column: "dept_id", autoincrement: false)))
        }
        let mirror = SQLiteMirror()
        try mirror.exec(
            """
            CREATE TABLE emp(id INTEGER PRIMARY KEY, dept INTEGER, city TEXT);
            CREATE TABLE dept(dept_id INTEGER PRIMARY KEY, name TEXT);
            """)

        let cities = ["NYC", "LA", "SF"]
        for i in 1...30 {
            let values: [Value] = [.integer(Int64(i)), .integer(Int64(i % 2 + 1)), .text(cities[i % 3])]
            try db.writeSync { (txn) throws(DBError) in
                try txn.insert(into: "emp", ["id": values[0], "dept": values[1], "city": values[2]])
            }
            try mirror.insertRow("emp", ["id", "dept", "city"], values)
        }
        for (k, name) in [(1, "Eng"), (2, "Sales")] {
            let values: [Value] = [.integer(Int64(k)), .text(name)]
            try db.writeSync { (txn) throws(DBError) in
                try txn.insert(into: "dept", ["dept_id": values[0], "name": values[1]])
            }
            try mirror.insertRow("dept", ["dept_id", "name"], values)
        }
        return (db, mirror)
    }

    /// Each `DISTINCT` query (over join or aggregate) matches SQLite, and the
    /// dedup demonstrably collapsed rows (the result is smaller than the
    /// pre-`DISTINCT` cardinality the same query yields without `DISTINCT`).
    @Test func distinctMatchesSQLiteAcrossJoinAndAggregate() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try Self.make(dir)
        defer { db.close() }

        let cases: [(label: String, distinct: String, plain: String, ordered: Bool)] = [
            (
                "join distinct, unordered",
                "SELECT DISTINCT d.name FROM emp e JOIN dept d ON e.dept = d.dept_id",
                "SELECT d.name FROM emp e JOIN dept d ON e.dept = d.dept_id",
                false
            ),
            (
                "join distinct, ordered",
                "SELECT DISTINCT d.name FROM emp e JOIN dept d ON e.dept = d.dept_id ORDER BY d.name",
                "SELECT d.name FROM emp e JOIN dept d ON e.dept = d.dept_id",
                true
            ),
            (
                "join distinct multi-col, ordered",
                "SELECT DISTINCT e.city, d.name FROM emp e JOIN dept d ON e.dept = d.dept_id ORDER BY e.city, d.name",
                "SELECT e.city, d.name FROM emp e JOIN dept d ON e.dept = d.dept_id",
                true
            ),
            (
                "aggregate distinct count, unordered",
                "SELECT DISTINCT COUNT(*) FROM emp GROUP BY dept",
                "SELECT COUNT(*) FROM emp GROUP BY dept",
                false
            ),
            (
                "aggregate distinct group-key, ordered",
                "SELECT DISTINCT city FROM emp GROUP BY city, dept ORDER BY city",
                "SELECT city FROM emp GROUP BY city, dept ORDER BY city",
                true
            ),
        ]
        for (label, distinctSQL, plainSQL, ordered) in cases {
            let ours = try db.prepare(distinctSQL).all().map(\.values)
            let theirs = try mirror.query(distinctSQL)
            #expect(rowsMatch(ours, theirs, ordered: ordered), "\(label): ADSQL \(ours) vs SQLite \(theirs)")

            // The dedup did real work: the DISTINCT result is strictly smaller than
            // the same query without DISTINCT (so `deduplicate` actually collapsed rows).
            let plainCount = try db.prepare(plainSQL).all().count
            #expect(ours.count < plainCount, "\(label): expected collapse, got \(ours.count) of \(plainCount)")
        }
    }
}
