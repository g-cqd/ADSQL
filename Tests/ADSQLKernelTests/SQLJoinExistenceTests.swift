import ADSQLKernel
import ADSQLTestSupport
import Testing

/// Differential tests for the index-only existence join inner — specifically the
/// `fastExistence` single-seek + zero-copy probe-key fast path (UNIQUE index,
/// full-key equality) and its fallbacks (non-unique fan-out, NULL outer key,
/// type-boundary mismatch, prefix probes). Compared against SQLite on a fixture
/// with a UNIQUE secondary index, a non-unique index, and a composite UNIQUE
/// index, with duplicate and NULL framework values.
private enum JoinExistFixture {
    static let columns = ["id", "key", "framework", "score"]

    static let definition = TableDefinition(
        "docs",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("key", .text, notNull: true),
            ColumnDefinition("framework", .text),
            ColumnDefinition("score", .integer, notNull: true),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE docs(
          id INTEGER PRIMARY KEY, key TEXT NOT NULL, framework TEXT, score INTEGER NOT NULL);
        CREATE UNIQUE INDEX u_key ON docs(key);
        CREATE INDEX i_framework ON docs(framework);
        CREATE UNIQUE INDEX u_fw_score ON docs(framework, score);
        """

    static let indexes = [
        IndexDefinition("u_key", on: "docs", columns: ["key"], unique: true),
        IndexDefinition("i_framework", on: "docs", columns: ["framework"]),
        IndexDefinition("u_fw_score", on: "docs", columns: ["framework", "score"], unique: true),
    ]

    static let frameworks = ["UIKit", "SwiftUI", "Foundation"]

    static func rows() -> [[Value]] {
        (1...20).map { i in
            let framework: Value = i % 7 == 0 ? .null : .text(frameworks[i % frameworks.count])
            // score == id keeps (framework, score) unique even where framework repeats.
            return [.integer(Int64(i)), .text("doc\(i)"), framework, .integer(Int64(i))]
        }
    }

    static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
        let db = try Database.open(at: dir.file(name))
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(definition)
            for index in indexes { try txn.createIndex(index) }
        }
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

@Suite("SQL join existence fast path")
struct SQLJoinExistenceTests {
    static let queries: [String] = [
        // UNIQUE full-key equality → fastExistence (every outer hits exactly once).
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.key = a.key",
        // …with an outer-only WHERE (b stays unreferenced → still existence-only).
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.key = a.key WHERE a.score > 10",
        // LEFT + UNIQUE: all match → same count.
        "SELECT COUNT(*) FROM docs a LEFT JOIN docs b ON b.key = a.key",
        // LEFT where no outer matches (key vs framework) + NULL outer key → null-extend.
        "SELECT COUNT(*) FROM docs a LEFT JOIN docs b ON b.key = a.framework",
        // Non-UNIQUE equality → fan-out via the enumerating path (NULLs don't match).
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.framework = a.framework",
        // Type-boundary (TEXT key vs INTEGER id) → fastExistence falls back to Value path.
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.key = a.id",
        // Composite UNIQUE full-key equality → multi-field fastExistence (NULL fw falls back).
        "SELECT COUNT(*) FROM docs a JOIN docs b ON b.framework = a.framework AND b.score = a.score",
        // Composite UNIQUE LEFT — unmatched (NULL fw) rows null-extend.
        "SELECT COUNT(*) FROM docs a LEFT JOIN docs b ON b.framework = a.framework AND b.score = a.score",
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try JoinExistFixture.make(dir, "join-exist.adsql")
        defer { db.close() }

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }
}
