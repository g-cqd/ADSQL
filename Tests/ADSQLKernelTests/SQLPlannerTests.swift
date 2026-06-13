import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// `docs(id PK, key unique, framework, score, weight, title NOCASE)` with a
/// matching set of indexes, populated identically in ADSQL (with and without
/// indexes) and SQLite. The unindexed ADSQL copy is the planner-invariance
/// oracle; SQLite is the semantics oracle.
private enum IndexedDocs {
  static let columns = ["id", "key", "framework", "score", "weight", "title"]
  static let frameworks = ["UIKit", "SwiftUI", "Foundation", "Combine"]

  static let definition = TableDefinition(
    "docs",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("key", .text, notNull: true),
      ColumnDefinition("framework", .text),
      ColumnDefinition("score", .integer),
      ColumnDefinition("weight", .real),
      ColumnDefinition("title", .text, collation: .nocase),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let indexes = [
    IndexDefinition("u_key", on: "docs", columns: ["key"], unique: true),
    IndexDefinition("i_framework", on: "docs", columns: ["framework"]),
    IndexDefinition("i_score_weight", on: "docs", columns: ["score", "weight"]),
    IndexDefinition("i_title", on: "docs", columns: ["title"]),
  ]

  static let sqliteDDL = """
    CREATE TABLE docs(
      id INTEGER PRIMARY KEY, key TEXT NOT NULL, framework TEXT,
      score INTEGER, weight REAL, title TEXT COLLATE NOCASE);
    CREATE UNIQUE INDEX u_key ON docs(key);
    CREATE INDEX i_framework ON docs(framework);
    CREATE INDEX i_score_weight ON docs(score, weight);
    CREATE INDEX i_title ON docs(title);
    """

  static func rows() -> [[Value]] {
    var rows: [[Value]] = []
    let titles = ["Alpha", "beta", "ALPHA", "Gamma", "delta"]
    var rng = SplitMix64(seed: 0x1117_AC03)
    for i in 1...40 {
      let framework: Value = (i % 11 == 0) ? .null : .text(frameworks[i % frameworks.count])
      let score: Value = (i % 8 == 0) ? .null : .integer(Int64(i % 6))
      let weight: Value = (i % 7 == 0) ? .null : .real(Double(Int64(rng.next() % 1000)) / 100.0)
      let title: Value = (i % 9 == 0) ? .null : .text(titles[i % titles.count])
      rows.append([.integer(Int64(i)), .text("doc\(i)"), framework, score, weight, title])
    }
    return rows
  }

  static func adsql(_ dir: TempDir, _ name: String, withIndexes: Bool) throws -> Database {
    let db = try Database.open(at: dir.file(name))
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(definition)
      if withIndexes { for index in indexes { try txn.createIndex(index) } }
    }
    for row in rows() {
      let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
      try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "docs", dict) }
    }
    return db
  }

  static func sqlite() throws -> SQLiteMirror {
    let mirror = SQLiteMirror()
    try mirror.exec(sqliteDDL)
    for row in rows() { try mirror.insertRow("docs", columns, row) }
    return mirror
  }
}

// MARK: - Access-path selection

@Suite("SQL planner access paths")
struct SQLPlannerPathTests {
  static let expectations: [(sql: String, fragment: String)] = [
    ("SELECT * FROM docs", "SCAN docs"),
    ("SELECT id FROM docs WHERE id = 5", "USING ROWID"),
    ("SELECT id FROM docs WHERE 5 = id", "USING ROWID"),
    ("SELECT id FROM docs WHERE id IN (1, 2, 3)", "USING ROWID (IN)"),
    ("SELECT id FROM docs WHERE key = 'doc7'", "USING INDEX u_key"),
    ("SELECT id FROM docs WHERE framework = 'UIKit'", "USING INDEX i_framework"),
    ("SELECT id FROM docs WHERE framework IN ('UIKit', 'Combine')", "USING INDEX i_framework"),
    ("SELECT id FROM docs WHERE score = 3", "USING INDEX i_score_weight"),
    ("SELECT id FROM docs WHERE score = 3 AND weight > 1.0", "score=? AND weight range"),
    ("SELECT id FROM docs WHERE score > 2", "USING INDEX i_score_weight (score range)"),
    ("SELECT id FROM docs WHERE score BETWEEN 2 AND 4", "USING INDEX i_score_weight (score range)"),
    ("SELECT id FROM docs WHERE title LIKE 'a%'", "SCAN docs"),  // LIKE-prefix deferred
    ("SELECT id FROM docs ORDER BY id LIMIT 5", "SCAN docs"),
  ]

  @Test(arguments: expectations)
  func picksExpectedPath(_ expectation: (sql: String, fragment: String)) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try IndexedDocs.adsql(dir, "paths.adsql", withIndexes: true)
    defer { db.close() }
    let description = try db.prepare(expectation.sql).planDescription()
    #expect(description.contains(expectation.fragment), "\(expectation.sql) → \(description)")
  }

  /// The score=3 ∧ weight>1.0 probe uses i_score_weight; the result must equal
  /// the full-scan answer (residual correctness) and SQLite.
  @Test func compositePrefixPlusRangeMatches() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let indexed = try IndexedDocs.adsql(dir, "ix.adsql", withIndexes: true)
    let scan = try IndexedDocs.adsql(dir, "noix.adsql", withIndexes: false)
    let mirror = try IndexedDocs.sqlite()
    defer { indexed.close(); scan.close() }

    let sql = "SELECT id, score, weight FROM docs WHERE score = 3 AND weight > 1.0 ORDER BY weight, id"
    let a = try indexed.prepare(sql).all().map(\.values)
    let b = try scan.prepare(sql).all().map(\.values)
    let c = try mirror.query(sql)
    #expect(rowsMatch(a, b, ordered: true))
    #expect(rowsMatch(a, c, ordered: true))
    #expect(try indexed.prepare(sql).planDescription().contains("i_score_weight"))
  }
}

// MARK: - Superset + residual property test

@Suite("SQL planner residual equivalence")
struct SQLPlannerResidualTests {
  @Test(arguments: [UInt64(7), 19, 4242])
  func plannedEqualsScanAndSQLite(seed: UInt64) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let indexed = try IndexedDocs.adsql(dir, "p-ix.adsql", withIndexes: true)
    let scan = try IndexedDocs.adsql(dir, "p-noix.adsql", withIndexes: false)
    let mirror = try IndexedDocs.sqlite()
    defer { indexed.close(); scan.close() }

    var rng = SplitMix64(seed: seed)
    for _ in 0..<250 {
      let (sql, ordered) = Self.randomQuery(&rng)
      let planned = try indexed.prepare(sql).all().map(\.values)
      let scanned = try scan.prepare(sql).all().map(\.values)
      let oracle = try mirror.query(sql)
      #expect(rowsMatch(planned, scanned, ordered: ordered), "planner-invariance: \(sql)")
      #expect(rowsMatch(planned, oracle, ordered: ordered), "vs sqlite: \(sql)")
    }
  }

  private static func randomQuery(_ rng: inout SplitMix64) -> (sql: String, ordered: Bool) {
    func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
    let fw = IndexedDocs.frameworks

    let predicates: [String] = [
      "id = \(1 + rng.next() % 40)",
      "id IN (\(1 + rng.next() % 40), \(1 + rng.next() % 40), \(1 + rng.next() % 40))",
      "key = 'doc\(1 + rng.next() % 45)'",
      "framework = '\(pick(fw))'",
      "framework IN ('\(pick(fw))', '\(pick(fw))')",
      "framework IS NULL",
      "score = \(rng.next() % 6)",
      "score > \(rng.next() % 6)",
      "score >= \(rng.next() % 4) AND score < \(3 + rng.next() % 4)",
      "score = \(rng.next() % 6) AND weight > \(Double(rng.next() % 800) / 100.0)",
      "weight > \(Double(rng.next() % 1000) / 100.0)",
      "weight IS NOT NULL",
      "title = 'alpha'",
      "score BETWEEN \(rng.next() % 4) AND \(2 + rng.next() % 4)",
      "score NOT BETWEEN \(rng.next() % 4) AND \(2 + rng.next() % 4)",
      "id BETWEEN \(1 + rng.next() % 20) AND \(20 + rng.next() % 20)",
    ]

    var clauses: [String] = [pick(predicates)]
    if rng.next() % 2 == 0 { clauses.append(pick(predicates)) }
    let whereClause = "WHERE " + clauses.joined(separator: " AND ")

    let projections = ["*", "id", "id, score", "id, framework, weight"]
    var sql = "SELECT \(pick(projections)) FROM docs \(whereClause)"

    var ordered = false
    if rng.next() % 3 != 0 {
      // Always end ORDER BY on the unique id so ties are deterministic.
      let leads = ["", "score, ", "framework, ", "weight, ", "title, "]
      sql += " ORDER BY \(pick(leads))id"
      ordered = true
      // LIMIT/OFFSET only under a total order: an unordered LIMIT picks an
      // arbitrary (engine-dependent) subset and isn't comparable.
      if rng.next() % 2 == 0 {
        sql += " LIMIT \(rng.next() % 10)"
        if rng.next() % 2 == 0 { sql += " OFFSET \(rng.next() % 5)" }
      }
    }
    return (sql, ordered)
  }
}
