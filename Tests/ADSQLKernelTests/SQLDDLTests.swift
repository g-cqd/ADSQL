import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

@Suite("SQL DDL")
struct SQLDDLTests {
  /// A complete workflow expressed only in SQL — schema, index, data, query —
  /// must agree with SQLite, proving the surface stands alone without the
  /// relational API.
  @Test func fullSQLWorkflowMatchesSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ddl.adsql"))
    defer { db.close() }
    let mirror = SQLiteMirror()

    let script = [
      "CREATE TABLE docs(id INTEGER PRIMARY KEY, key TEXT NOT NULL, framework TEXT, score INTEGER DEFAULT 0)",
      "CREATE INDEX i_fw ON docs(framework)",
      "INSERT INTO docs(id, key, framework, score) VALUES(1, 'a', 'UIKit', 5)",
      "INSERT INTO docs(id, key, framework) VALUES(2, 'b', 'SwiftUI')",
      "INSERT INTO docs VALUES(3, 'c', 'UIKit', 9)",
      "INSERT INTO docs(id, key, framework, score) VALUES(4, 'd', 'Foundation', 2)",
    ]
    for sql in script {
      try db.prepare(sql).run()
      try mirror.exec(sql)
    }

    for query in [
      "SELECT id, key, framework, score FROM docs ORDER BY id",
      "SELECT id FROM docs WHERE framework = 'UIKit' ORDER BY id",
      "SELECT framework, COUNT(*), SUM(score) FROM docs GROUP BY framework ORDER BY framework",
    ] {
      let ours = try db.prepare(query).all().map(\.values)
      let theirs = try mirror.query(query)
      #expect(rowsMatch(ours, theirs, ordered: true), "\(query): \(ours) vs \(theirs)")
    }

    // The SQL-created index is visible to the planner.
    let plan = try db.prepare("SELECT id FROM docs WHERE framework = 'UIKit'").planDescription()
    #expect(plan.contains("USING INDEX i_fw"), "\(plan)")
  }

  @Test func ifNotExistsAndIfExists() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ifexists.adsql"))
    defer { db.close() }

    try db.prepare("CREATE TABLE t(a INTEGER)").run()
    // Re-create without IF NOT EXISTS → error; with it → no-op.
    #expect(throws: DBError.self) { try db.prepare("CREATE TABLE t(a INTEGER)").run() }
    try db.prepare("CREATE TABLE IF NOT EXISTS t(a INTEGER, b TEXT)").run()  // no-op, keeps original

    try db.prepare("INSERT INTO t(a) VALUES(1)").run()
    // Original single-column schema preserved (the IF NOT EXISTS was a no-op).
    #expect(try db.prepare("SELECT * FROM t").all()[0].columns == ["a"])

    // DROP IF EXISTS on a missing table is a no-op; plain DROP errors.
    try db.prepare("DROP TABLE IF EXISTS missing").run()
    #expect(throws: DBError.self) { try db.prepare("DROP TABLE missing").run() }

    try db.prepare("DROP TABLE t").run()
    #expect(throws: DBError.self) { try db.prepare("SELECT * FROM t").all() }
  }

  @Test func createAndDropIndex() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("idx.adsql"))
    defer { db.close() }

    try db.prepare("CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)").run()
    try db.prepare("CREATE UNIQUE INDEX u_k ON t(k)").run()
    try db.prepare("INSERT INTO t VALUES(1, 'x')").run()
    // Unique index enforced through SQL.
    #expect(throws: DBError.self) { try db.prepare("INSERT INTO t VALUES(2, 'x')").run() }

    try db.prepare("DROP INDEX u_k").run()
    // After dropping the unique index the duplicate is allowed.
    try db.prepare("INSERT INTO t VALUES(2, 'x')").run()
    #expect(try db.prepare("SELECT COUNT(*) FROM t").all()[0].values == [.integer(2)])
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func schemaSurvivesReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("persist.adsql"))
    try db.prepare("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)").run()
    try db.prepare("CREATE INDEX i_v ON t(v)").run()
    try db.prepare("INSERT INTO t VALUES(1, 'hello')").run()
    db.close()

    let reopened = try Database.open(at: dir.file("persist.adsql"))
    defer { reopened.close() }
    #expect(try reopened.prepare("SELECT v FROM t WHERE id = 1").all()[0].values == [.text("hello")])
    let plan = try reopened.prepare("SELECT id FROM t WHERE v = 'hello'").planDescription()
    #expect(plan.contains("USING INDEX i_v"), "\(plan)")
    _ = try reopened.verifyIntegrity(deep: true)
  }

  /// Regression: an over-long column name surfaces a catchable `DBError`
  /// instead of tripping the catalog encoder's length `precondition` (which
  /// aborted the process). The 255-byte boundary still round-trips.
  @Test func rejectsOverLongColumnNameWithoutTrapping() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("longcol.adsql"))
    defer { db.close() }

    let tooLong = String(repeating: "a", count: 256)
    #expect(throws: DBError.invalidDefinition("table t: column name too long (max 255 bytes)")) {
      try db.prepare("CREATE TABLE t(\(tooLong) INTEGER)").run()
    }

    let atLimit = String(repeating: "b", count: 255)
    try db.prepare("CREATE TABLE u(\(atLimit) INTEGER)").run()
    let columns: [String]? = try db.writeSync { (txn) throws(DBError) in
      try txn.schema().tables["u"]?.columns.map(\.name)
    }
    #expect(columns == [atLimit])
  }
}
