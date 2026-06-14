import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// `docs(id, key, framework)` LEFT/INNER joined to `roots(id, slug, display)`
/// on framework=slug. Frameworks include matched, unmatched ('Combine'), and
/// NULL values; one matched root has a NULL display — so the fixture exercises
/// null-extension, ON-vs-WHERE placement, and NULL filtering. slug is unique,
/// so each doc matches at most one root and d.id is a total order over join
/// results (deterministic ordered comparison).
private enum JoinFixture {
    static let docColumns = ["id", "key", "framework"]
    static let rootColumns = ["id", "slug", "display"]

    static let docs = TableDefinition(
        "docs",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("key", .text, notNull: true),
            ColumnDefinition("framework", .text),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let roots = TableDefinition(
        "roots",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("slug", .text, notNull: true),
            ColumnDefinition("display", .text),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let frameworks = ["UIKit", "SwiftUI", "Foundation", "Combine", "Metal"]

    static func rootRows() -> [[Value]] {
        [
            [.integer(1), .text("UIKit"), .text("UI Kit")],
            [.integer(2), .text("SwiftUI"), .text("Swift UI")],
            [.integer(3), .text("Foundation"), .text("Foundation")],
            [.integer(4), .text("Metal"), .null],  // matched but NULL display
        ]
    }

    static func docRows() -> [[Value]] {
        var rows: [[Value]] = []
        for i in 1...20 {
            let framework: Value = (i % 6 == 0) ? .null : .text(frameworks[i % frameworks.count])
            rows.append([.integer(Int64(i)), .text("doc\(i)"), framework])
        }
        return rows
    }

    static let sqliteDDL = """
        CREATE TABLE roots(id INTEGER PRIMARY KEY, slug TEXT NOT NULL, display TEXT);
        CREATE TABLE docs(id INTEGER PRIMARY KEY, key TEXT NOT NULL, framework TEXT);
        CREATE INDEX i_framework ON docs(framework);
        """

    static func adsql(_ dir: TempDir, _ name: String) throws -> Database {
        let db = try Database.open(at: dir.file(name))
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(roots)
            try txn.createTable(docs)
            try txn.createIndex(IndexDefinition("i_framework", on: "docs", columns: ["framework"]))
        }
        for row in rootRows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(rootColumns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "roots", dict) }
        }
        for row in docRows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(docColumns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "docs", dict) }
        }
        return db
    }

    static func sqlite() throws -> SQLiteMirror {
        let mirror = SQLiteMirror()
        try mirror.exec(sqliteDDL)
        for row in rootRows() { try mirror.insertRow("roots", rootColumns, row) }
        for row in docRows() { try mirror.insertRow("docs", docColumns, row) }
        return mirror
    }
}

@Suite("SQL joins")
struct SQLJoinTests {
    static let queries: [String] = [
        "SELECT d.id, d.key, r.display FROM docs d JOIN roots r ON r.slug = d.framework ORDER BY d.id",
        "SELECT d.id, r.display FROM docs d LEFT JOIN roots r ON r.slug = d.framework ORDER BY d.id",
        "SELECT d.id FROM docs d LEFT JOIN roots r ON r.slug = d.framework WHERE r.id IS NULL ORDER BY d.id",
        "SELECT d.id, r.slug FROM docs d JOIN roots r ON r.slug = d.framework WHERE d.framework = 'UIKit' ORDER BY d.id",
        "SELECT d.id, r.display FROM docs d LEFT JOIN roots r ON r.slug = d.framework AND r.id > 2 ORDER BY d.id",
        "SELECT d.id FROM docs d LEFT JOIN roots r ON r.slug = d.framework WHERE r.display IS NOT NULL ORDER BY d.id",
        "SELECT * FROM docs d JOIN roots r ON r.slug = d.framework ORDER BY d.id",
        "SELECT d.id, COALESCE(r.display, '<none>') AS name FROM docs d LEFT JOIN roots r ON r.slug = d.framework ORDER BY d.id",
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try JoinFixture.adsql(dir, "join.adsql")
        defer { db.close() }
        let mirror = try JoinFixture.sqlite()

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }

    @Test func outerTableUsesIndex() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try JoinFixture.adsql(dir, "join-plan.adsql")
        defer { db.close() }

        let indexed = try db.prepare(
            "SELECT d.id FROM docs d JOIN roots r ON r.slug = d.framework WHERE d.framework = 'UIKit'"
        ).planDescription()
        #expect(indexed.contains("USING INDEX i_framework"), "\(indexed)")

        let scan = try db.prepare(
            "SELECT d.id FROM docs d JOIN roots r ON r.slug = d.framework"
        ).planDescription()
        #expect(scan.contains("SCAN docs"), "\(scan)")
    }
}

@Suite("SQL join residual equivalence")
struct SQLJoinResidualTests {
    @Test(arguments: [UInt64(3), 31, 991])
    func randomJoinsMatchSQLite(seed: UInt64) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try JoinFixture.adsql(dir, "join-rand.adsql")
        defer { db.close() }
        let mirror = try JoinFixture.sqlite()

        var rng = SplitMix64(seed: seed)
        for _ in 0..<150 {
            let sql = Self.randomJoin(&rng)
            let ours = try db.prepare(sql).all().map(\.values)
            let theirs = try mirror.query(sql)
            #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
        }
    }

    private static func randomJoin(_ rng: inout SplitMix64) -> String {
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let kind = pick(["JOIN", "LEFT JOIN"])
        var on = "r.slug = d.framework"
        if rng.next() % 3 == 0 { on += " AND r.id > \(rng.next() % 4)" }

        var clauses: [String] = []
        let predicates = [
            "d.framework = '\(pick(JoinFixture.frameworks))'",
            "d.id < \(5 + rng.next() % 18)",
            "r.display IS NULL",
            "r.display IS NOT NULL",
            "r.id >= \(rng.next() % 4)",
            "d.framework IS NOT NULL",
        ]
        if rng.next() % 2 == 0 { clauses.append(pick(predicates)) }
        if rng.next() % 3 == 0 { clauses.append(pick(predicates)) }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")

        let projection = pick(["d.id, r.display", "d.id, d.framework, r.slug", "*", "d.id"])
        var sql = "SELECT \(projection) FROM docs d \(kind) roots r ON \(on)\(whereClause) ORDER BY d.id"
        if rng.next() % 2 == 0 { sql += " LIMIT \(rng.next() % 12)" }
        return sql
    }
}
