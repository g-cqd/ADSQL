import ADSQLKernel
import ADSQLTestSupport
import Testing

/// Differential validation of the hash-join driver: every INNER equi-join must
/// produce identical results under `.nestedLoop` and `.hash` AND match SQLite —
/// including the unique self-join (benchmark), non-unique fan-out, multi-column
/// keys, NULL keys (no match), a non-equi residual ON, and an ineligible
/// type-mismatched key (which falls back to nested loop). LEFT joins fall back to
/// nested loop under `.hash`, so they too must stay identical.
private enum HashJoinFixture {
    static let columns = ["id", "key", "framework", "score"]

    static let definition = TableDefinition(
        "docs",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("key", .text, notNull: true),
            ColumnDefinition("framework", .text),
            ColumnDefinition("score", .integer),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE docs(id INTEGER PRIMARY KEY, key TEXT NOT NULL, framework TEXT, score INTEGER)
        """

    static let frameworks = ["UIKit", "SwiftUI", "Foundation"]

    static func rows() -> [[Value]] {
        (1...24).map { i in
            let framework: Value = i % 7 == 0 ? .null : .text(frameworks[i % frameworks.count])
            let score: Value = i % 5 == 0 ? .null : .integer(Int64(i % 4))
            return [.integer(Int64(i)), .text("doc\(i)"), framework, score]
        }
    }

    static func make(_ dir: TempDir, join: ExecutionOptions.Join) throws -> Database {
        let db = try Database.open(
            at: dir.file("hashjoin-\(join).adsql"),
            options: DatabaseOptions(execution: ExecutionOptions(join: join)))
        try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
        // A UNIQUE index on the join key so `ON b.key = a.key` binds to an exact index
        // probe → innerExistenceOnly → exercises the hash SEMI-join (per-key count) path.
        try db.prepare("CREATE UNIQUE INDEX ux_docs_key ON docs(key)").run()
        for row in rows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "docs", dict) }
        }
        return db
    }

    static func mirror() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(sqliteDDL)
        try m.exec("CREATE UNIQUE INDEX ux_docs_key ON docs(key)")
        for row in rows() { try m.insertRow("docs", columns, row) }
        return m
    }
}

@Suite("SQL hash join differential")
struct SQLHashJoinTests {
    static let joins: [ExecutionOptions.Join] = [.nestedLoop, .hash, .merge, .auto]

    static let queries: [String] = [
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.key = a.key",  // unique self-join
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.framework = a.framework",  // fan-out, NULLs excluded
        "SELECT a.id, b.id FROM docs a JOIN docs b ON b.framework = a.framework ORDER BY a.id, b.id",
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.framework = a.framework AND b.score = a.score",  // multi-key
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.framework = a.framework AND b.id > a.id",  // equi + residual
        // WHERE + project
        "SELECT a.key, b.score FROM docs a JOIN docs b ON b.key = a.key WHERE a.score > 1 ORDER BY a.id",
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.key = a.id",  // type mismatch → fallback
        "SELECT COUNT(*) FROM docs a LEFT JOIN docs b ON b.framework = a.framework",  // LEFT → fallback
    ]

    @Test(arguments: queries)
    func nestedLoopAndHashAgreeWithSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let theirs = try HashJoinFixture.mirror().query(sql)
        let ordered = sql.lowercased().contains("order by")

        var reference: [[Value]]?
        for join in Self.joins {
            let db = try HashJoinFixture.make(dir, join: join)
            defer { db.close() }
            let ours = try db.prepare(sql).all().map(\.values)
            #expect(rowsMatch(ours, theirs, ordered: ordered), "\(join) \(sql): \(ours) vs sqlite \(theirs)")
            if let reference {
                #expect(rowsMatch(ours, reference, ordered: ordered), "\(join) diverged on \(sql)")
            } else {
                reference = ours
            }
        }
    }

    /// R2 — general 2-table merge: two DIFFERENT tables, each with a UNIQUE NOT-NULL
    /// key index, joined on the key. `COUNT(*)` = the key intersection. `.merge`/
    /// `.auto` lock-step the two indexes; the result must equal `.nestedLoop`/`.hash`
    /// and SQLite.
    @Test func twoTableMergeExistenceMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let ddl = [
            "CREATE TABLE ta(id INTEGER PRIMARY KEY, k TEXT NOT NULL)",
            "CREATE TABLE tb(id INTEGER PRIMARY KEY, k TEXT NOT NULL)",
            "CREATE UNIQUE INDEX uka ON ta(k)",
            "CREATE UNIQUE INDEX ukb ON tb(k)",
        ]
        let query = "SELECT COUNT(*) FROM ta a JOIN tb b ON a.k = b.k"

        let m = SQLiteMirror()
        for sql in ddl { try m.exec(sql) }
        for i in 1...30 { try m.exec("INSERT INTO ta(k) VALUES('k\(i)')") }
        for i in 10...40 { try m.exec("INSERT INTO tb(k) VALUES('k\(i)')") }
        let expected = try m.query(query)  // intersection k10..k30 = 21

        var reference: [[Value]]?
        for join in Self.joins {
            let db = try Database.open(
                at: dir.file("twotable-\(join).adsql"),
                options: DatabaseOptions(execution: ExecutionOptions(join: join)))
            defer { db.close() }
            for sql in ddl { try db.prepare(sql).run() }
            for i in 1...30 { try db.prepare("INSERT INTO ta(k) VALUES('k\(i)')").run() }
            for i in 10...40 { try db.prepare("INSERT INTO tb(k) VALUES('k\(i)')").run() }
            let ours = try db.prepare(query).all().map(\.values)
            #expect(ours == expected, "\(join): \(ours) vs sqlite \(expected)")
            if let reference { #expect(ours == reference, "\(join) diverged") } else { reference = ours }
        }
        #expect(expected == [[.integer(21)]], "sanity: intersection is 21")
    }
}
