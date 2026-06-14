import ADSQLKernel
import ADSQLTestSupport
import Testing

/// The cross-strategy differential gate: the SAME query must produce identical
/// results under every execution strategy AND match the SQLite oracle. This is
/// the accuracy/consistency safety net that lets alternative strategies (here the
/// compiled-closure evaluator) be added beside the reference tree-walk path. As
/// more strategies land (hash/merge join, VDBE, insert paths) they join the matrix.
private enum MatrixFixture {
  static let columns = ["id", "name", "tag", "score", "weight"]

  static let definition = TableDefinition(
    "t",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("name", .text, notNull: true),        // BINARY
      ColumnDefinition("tag", .text, collation: .nocase),    // NOCASE, NULLs
      ColumnDefinition("score", .integer),                   // NULLs
      ColumnDefinition("weight", .real),                     // NULLs
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let sqliteDDL = """
    CREATE TABLE t(
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, tag TEXT COLLATE NOCASE,
      score INTEGER, weight REAL)
    """

  static let names = ["alpha", "Bravo", "charlie", "Delta", "echo"]
  static let tags = ["X", "y", "Z"]

  static func rows() -> [[Value]] {
    (1...25).map { i in
      let tag: Value = i % 6 == 0 ? .null : .text(tags[i % tags.count])
      let score: Value = i % 5 == 0 ? .null : .integer(Int64(i % 8) - 3)
      let weight: Value = i % 4 == 0 ? .null : .real(Double(i) / 2 - 5)
      return [.integer(Int64(i)), .text(names[i % names.count]), tag, score, weight]
    }
  }

  static func make(_ dir: TempDir, evaluator: ExecutionOptions.Evaluator) throws -> Database {
    let db = try Database.open(
      at: dir.file("matrix-\(evaluator).adsql"),
      options: DatabaseOptions(execution: ExecutionOptions(evaluator: evaluator)))
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
    for row in rows() {
      let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
      try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "t", dict) }
    }
    return db
  }

  static func mirror() throws -> SQLiteMirror {
    let m = SQLiteMirror()
    try m.exec(sqliteDDL)
    for row in rows() { try m.insertRow("t", columns, row) }
    return m
  }
}

@Suite("SQL strategy matrix — evaluators")
struct SQLStrategyMatrixTests {
  static let evaluators: [ExecutionOptions.Evaluator] = [.treeWalk, .compiledClosures]

  static let queries: [String] = [
    "SELECT id, name FROM t WHERE score > 2 ORDER BY id",                 // comparison + numeric affinity
    "SELECT id FROM t WHERE name = 'Bravo' ORDER BY id",                  // TEXT BINARY compare
    "SELECT id, tag FROM t WHERE tag = 'x' ORDER BY id",                  // TEXT NOCASE compare
    "SELECT id, score * 2 AS d FROM t WHERE score IS NOT NULL ORDER BY id",  // arithmetic + IS NULL
    "SELECT id FROM t WHERE score >= 0 AND weight < 0 ORDER BY id",       // AND + mixed types + NULLs
    "SELECT id FROM t WHERE score > 3 OR name = 'alpha' ORDER BY id",     // OR
    "SELECT id, CASE WHEN score > 2 THEN 'hi' WHEN score < 0 THEN 'lo' ELSE 'mid' END AS c FROM t ORDER BY id",
    "SELECT id FROM t WHERE -score > 0 ORDER BY id",                      // unary negate
    "SELECT id FROM t WHERE CAST(score AS TEXT) = '4' ORDER BY id",       // cast
    "SELECT id, name FROM t WHERE name >= 'a' ORDER BY name, id LIMIT 4",  // bounded top-N (total order)
    "SELECT DISTINCT tag FROM t",                                         // distinct projection (NOCASE)
    "SELECT id FROM t WHERE name = 'Bravo' COLLATE NOCASE ORDER BY id",   // explicit COLLATE
    "SELECT id, name || '!' AS n FROM t WHERE id <= 3 ORDER BY id",       // concat
  ]

  @Test(arguments: queries)
  func everyEvaluatorAgreesAndMatchesSQLite(_ sql: String) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let mirror = try MatrixFixture.mirror()
    let theirs = try mirror.query(sql)
    let ordered = sql.lowercased().contains("order by")

    var reference: [[Value]]?
    for evaluator in Self.evaluators {
      let db = try MatrixFixture.make(dir, evaluator: evaluator)
      defer { db.close() }
      let ours = try db.prepare(sql).all().map(\.values)
      // Every strategy must match the external oracle …
      #expect(rowsMatch(ours, theirs, ordered: ordered), "\(evaluator) \(sql): \(ours) vs sqlite \(theirs)")
      // … and produce identical results to the reference strategy.
      if let reference {
        #expect(rowsMatch(ours, reference, ordered: ordered), "\(evaluator) diverged on \(sql)")
      } else {
        reference = ours
      }
    }
  }
}
