import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// `docs(id, framework, score, weight)` with repeated frameworks, NULL
/// frameworks/scores, and mixed int/real-summable weights — exercises
/// COUNT(*) vs COUNT(col), SUM (NULL-skipping, REAL promotion, empty→NULL),
/// GROUP BY (incl. a NULL group), and HAVING.
private enum AggFixture {
    static let columns = ["id", "framework", "score", "weight"]
    static let frameworks = ["UIKit", "SwiftUI", "Foundation"]

    static let definition = TableDefinition(
        "docs",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("framework", .text),
            ColumnDefinition("score", .integer),
            ColumnDefinition("weight", .real),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE docs(id INTEGER PRIMARY KEY, framework TEXT, score INTEGER, weight REAL)
        """

    static func rows() -> [[Value]] {
        var rows: [[Value]] = []
        for i in 1...24 {
            let framework: Value = (i % 7 == 0) ? .null : .text(frameworks[i % frameworks.count])
            let score: Value = (i % 5 == 0) ? .null : .integer(Int64(i % 4))
            let weight: Value = .real(Double(i) / 2.0)
            rows.append([.integer(Int64(i)), framework, score, weight])
        }
        return rows
    }

    static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
        let db = try Database.open(at: dir.file(name))
        try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
        let mirror = SQLiteMirror()
        try mirror.exec(sqliteDDL)
        for row in rows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "docs", dict) }
            try mirror.insertRow("docs", columns, row)
        }
        return (db, mirror)
    }
}

@Suite("SQL aggregates")
struct SQLAggregateTests {
    static let queries: [String] = [
        "SELECT COUNT(*) FROM docs",
        "SELECT COUNT(score) FROM docs",
        "SELECT COUNT(*), COUNT(score), COUNT(framework) FROM docs",
        "SELECT SUM(score) FROM docs",
        "SELECT SUM(weight) FROM docs",
        "SELECT SUM(score), SUM(weight) FROM docs",
        "SELECT COUNT(*) FROM docs WHERE score > 1",
        "SELECT SUM(score) FROM docs WHERE framework = 'Nonexistent'",
        "SELECT COUNT(*) FROM docs WHERE framework = 'Nonexistent'",
        "SELECT framework, COUNT(*) FROM docs GROUP BY framework ORDER BY framework",
        "SELECT framework, COUNT(*) AS c, SUM(score) AS s FROM docs GROUP BY framework ORDER BY framework",
        "SELECT score, COUNT(*) FROM docs GROUP BY score ORDER BY score",
        "SELECT framework, COUNT(*) FROM docs GROUP BY framework HAVING COUNT(*) > 2 ORDER BY framework",
        "SELECT framework, SUM(score) FROM docs GROUP BY framework HAVING SUM(score) >= 5 ORDER BY framework",
        "SELECT framework FROM docs GROUP BY framework ORDER BY framework",
        "SELECT framework, COUNT(*) AS c FROM docs GROUP BY framework ORDER BY c DESC, framework",
        "SELECT framework, COUNT(*) * 2 AS doubled FROM docs GROUP BY framework ORDER BY framework",
        "SELECT COUNT(*) AS total FROM docs GROUP BY framework HAVING COUNT(score) > 0 ORDER BY framework",
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try AggFixture.make(dir, "agg.adsql")
        defer { db.close() }

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        let ordered = sql.lowercased().contains("order by")
        #expect(rowsMatch(ours, theirs, ordered: ordered), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }

    // Order-deterministic JSON aggregates: a full scan visits rows in rowid order in both
    // engines, so json_group_array/json_group_object emit elements in the same order.
    static let jsonQueries: [String] = [
        "SELECT json_group_array(id) FROM docs",
        "SELECT json_group_array(score) FROM docs",
        "SELECT json_group_array(framework) FROM docs WHERE framework IS NOT NULL",
        "SELECT framework, json_group_array(id) FROM docs GROUP BY framework ORDER BY framework",
        "SELECT json_group_object(framework, id) FROM docs WHERE id <= 6",
        "SELECT framework, json_group_object(framework, score) FROM docs"
            + " WHERE framework IS NOT NULL GROUP BY framework ORDER BY framework",
        // Aggregate over zero rows (no GROUP BY still yields one row).
        "SELECT json_group_array(id) FROM docs WHERE id < 0",
        "SELECT json_group_object(framework, id) FROM docs WHERE id < 0",
    ]

    @Test(arguments: jsonQueries)
    func jsonAggregatesMatchSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try AggFixture.make(dir, "json-agg.adsql")
        defer { db.close() }

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        let ordered = sql.lowercased().contains("order by")
        #expect(rowsMatch(ours, theirs, ordered: ordered), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }

    @Test func emptyTableAggregates() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("empty.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in try txn.createTable(AggFixture.definition) }

        // No GROUP BY over an empty table still yields one row.
        let counts = try db.prepare("SELECT COUNT(*), SUM(score) FROM docs").all()
        #expect(counts.count == 1)
        #expect(counts[0].values == [.integer(0), .null])

        // GROUP BY over an empty table yields no rows.
        let grouped = try db.prepare("SELECT framework, COUNT(*) FROM docs GROUP BY framework").all()
        #expect(grouped.isEmpty)
    }

    @Test func sumIntegerOverflowThrows() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("overflow.adsql"))
        defer { db.close() }
        let table = TableDefinition(
            "t", columns: [ColumnDefinition("v", .integer)])
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(table)
            try txn.insert(into: "t", ["v": .integer(.max)])
            try txn.insert(into: "t", ["v": .integer(.max)])
        }
        #expect(throws: DBError.self) { try db.prepare("SELECT SUM(v) FROM t").all() }
    }
}

@Suite("SQL aggregate residual equivalence")
struct SQLAggregateResidualTests {
    @Test(arguments: [UInt64(5), 55, 555])
    func randomAggregatesMatchSQLite(seed: UInt64) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try AggFixture.make(dir, "agg-rand.adsql")
        defer { db.close() }

        var rng = SplitMix64(seed: seed)
        for _ in 0..<150 {
            let sql = Self.randomAggregate(&rng)
            let ours = try db.prepare(sql).all().map(\.values)
            let theirs = try mirror.query(sql)
            #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
        }
    }

    private static func randomAggregate(_ rng: inout SplitMix64) -> String {
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let aggregates = ["COUNT(*)", "COUNT(score)", "SUM(score)", "SUM(weight)", "COUNT(framework)"]
        let agg = pick(aggregates)
        let groupCol = pick(["framework", "score"])

        var clauses: [String] = []
        if rng.next() % 2 == 0 {
            clauses.append(pick(["score > 1", "framework IS NOT NULL", "id < 15", "weight > 3.0"]))
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")

        // GROUP BY a column with a deterministic ORDER BY on the same column.
        var sql = "SELECT \(groupCol), \(agg) AS a FROM docs\(whereClause)"
        sql += " GROUP BY \(groupCol)"
        if rng.next() % 2 == 0 {
            sql += " HAVING \(pick(["COUNT(*) > 1", "COUNT(*) >= 2", "SUM(score) > 3"]))"
        }
        sql += " ORDER BY \(groupCol)"
        return sql
    }
}
