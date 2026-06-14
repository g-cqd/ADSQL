import ADSQLKernel
import ADSQLTestSupport
import Testing

/// Differential tests for `SELECT DISTINCT` over an indexed table — exercising
/// the index-ordered DISTINCT path (decode distinct key prefixes straight from
/// the index, no table descent) and its fallbacks. Compared against SQLite on an
/// indexed fixture with duplicates and NULLs across BINARY text, multi-column,
/// integer, NOCASE text, and an unindexed column.
private enum DistinctFixture {
    static let columns = ["id", "framework", "kind", "score", "title"]

    static let definition = TableDefinition(
        "items",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("framework", .text),
            ColumnDefinition("kind", .text),
            ColumnDefinition("score", .integer),
            ColumnDefinition("title", .text, collation: .nocase),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE items(
          id INTEGER PRIMARY KEY, framework TEXT, kind TEXT, score INTEGER,
          title TEXT COLLATE NOCASE);
        CREATE INDEX i_fw ON items(framework);
        CREATE INDEX i_fw_kind ON items(framework, kind);
        CREATE INDEX i_score ON items(score);
        CREATE INDEX i_title ON items(title);
        """

    static let indexes = [
        IndexDefinition("i_fw", on: "items", columns: ["framework"]),
        IndexDefinition("i_fw_kind", on: "items", columns: ["framework", "kind"]),
        IndexDefinition("i_score", on: "items", columns: ["score"]),
        IndexDefinition("i_title", on: "items", columns: ["title"]),
    ]

    static let frameworks = ["SwiftUI", "UIKit", "Foundation"]
    static let kinds = ["symbol", "article"]
    static let titles = ["Alpha", "alpha", "BETA"]

    static func rows() -> [[Value]] {
        var rows: [[Value]] = []
        for i in 1...30 {
            let framework: Value = (i % 7 == 0) ? .null : .text(frameworks[i % frameworks.count])
            let kind: Value = .text(kinds[i % kinds.count])
            let score: Value = (i % 5 == 0) ? .null : .integer(Int64(i % 4))
            let title: Value = (i % 9 == 0) ? .null : .text(titles[i % titles.count])
            rows.append([.integer(Int64(i)), framework, kind, score, title])
        }
        return rows
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
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "items", dict) }
            try mirror.insertRow("items", columns, row)
        }
        return (db, mirror)
    }
}

@Suite("SQL DISTINCT over indexes")
struct SQLDistinctIndexTests {
    static let queries: [String] = [
        "SELECT DISTINCT framework FROM items",  // BINARY text + NULL → index path
        "SELECT DISTINCT framework, kind FROM items",  // multi-column BINARY → index path
        "SELECT DISTINCT score FROM items",  // INTEGER + NULL → index path
        "SELECT DISTINCT kind FROM items",  // no single-col index → fallback
        "SELECT DISTINCT title FROM items",  // NOCASE text → fallback (lossy key)
        "SELECT DISTINCT framework FROM items ORDER BY framework",  // ordered → row path
        "SELECT DISTINCT framework, kind FROM items ORDER BY framework, kind",
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try DistinctFixture.make(dir, "distinct.adsql")
        defer { db.close() }

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        let ordered = sql.lowercased().contains("order by")
        #expect(rowsMatch(ours, theirs, ordered: ordered), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }
}
