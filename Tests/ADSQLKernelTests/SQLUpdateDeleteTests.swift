import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// `t(id PK, grp, qty, name)` created in both engines and seeded via SQL
/// INSERT, then mutated by identical UPDATE/DELETE scripts.
private enum MutationFixture {
  static let definition = TableDefinition(
    "t",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("grp", .text),
      ColumnDefinition("qty", .integer),
      ColumnDefinition("name", .text),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let sqliteDDL = "CREATE TABLE t(id INTEGER PRIMARY KEY, grp TEXT, qty INTEGER, name TEXT)"

  static let seed = [
    "INSERT INTO t VALUES(1, 'a', 5, 'one')",
    "INSERT INTO t VALUES(2, 'a', 15, 'two')",
    "INSERT INTO t VALUES(3, 'b', 25, 'three')",
    "INSERT INTO t VALUES(4, 'b', 3, 'four')",
    "INSERT INTO t VALUES(5, NULL, 8, 'five')",
  ]

  static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
    let db = try Database.open(at: dir.file(name))
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
    let mirror = SQLiteMirror()
    try mirror.exec(sqliteDDL)
    for sql in seed {
      try db.prepare(sql).run()
      try mirror.exec(sql)
    }
    return (db, mirror)
  }

  static func state(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, grp, qty, name FROM t ORDER BY id").all().map(\.values)
  }
  static func state(_ mirror: SQLiteMirror) throws -> [[Value]] {
    try mirror.query("SELECT id, grp, qty, name FROM t ORDER BY id")
  }
}

@Suite("SQL UPDATE / DELETE")
struct SQLUpdateDeleteTests {
  @Test func mutationScriptMatchesSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try MutationFixture.make(dir, "mutate.adsql")
    defer { db.close() }

    let statements = [
      "UPDATE t SET qty = qty + 100 WHERE grp = 'a'",
      "UPDATE t SET name = 'BIG' WHERE qty > 50",
      "UPDATE t SET grp = 'z'",  // no WHERE: all rows
      "DELETE FROM t WHERE qty < 10",
      "UPDATE t SET qty = qty * 2 WHERE id = 3",
      "DELETE FROM t WHERE grp = 'nope'",  // matches nothing
    ]
    for sql in statements {
      try db.prepare(sql).run()
      try mirror.exec(sql)
      #expect(try MutationFixture.state(db) == MutationFixture.state(mirror), "after: \(sql)")
    }
  }

  @Test func updateRunResultAndReturning() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try MutationFixture.make(dir, "upd.adsql")
    defer { db.close() }

    let result = try db.prepare("UPDATE t SET qty = qty + 1 WHERE grp = 'a'").run()
    #expect(result.changes == 2)

    // RETURNING reflects post-update values.
    let returned = try db.prepare(
      "UPDATE t SET qty = 0 WHERE id = 3 RETURNING id, qty"
    ).all()
    #expect(returned.map(\.values) == [[.integer(3), .integer(0)]])
  }

  @Test func deleteRunResultAndReturning() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try MutationFixture.make(dir, "del.adsql")
    defer { db.close() }

    // RETURNING reflects the pre-delete row.
    let returned = try db.prepare("DELETE FROM t WHERE id = 2 RETURNING id, name").all()
    #expect(returned.map(\.values) == [[.integer(2), .text("two")]])

    let result = try db.prepare("DELETE FROM t WHERE qty > 5").run()
    #expect(result.changes == 2)  // rows 3 and 5 remain after row 2 gone (qty 25, 8)

    let remaining = try db.prepare("SELECT COUNT(*) FROM t").all()
    #expect(remaining[0].values == [.integer(2)])  // ids 1 (qty 5) and 4 (qty 3)
  }

  @Test func deleteAllEmptiesTable() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try MutationFixture.make(dir, "delall.adsql")
    defer { db.close() }

    let result = try db.prepare("DELETE FROM t").run()
    #expect(result.changes == 5)
    try mirror.exec("DELETE FROM t")
    #expect(try MutationFixture.state(db) == MutationFixture.state(mirror))
    #expect(try MutationFixture.state(db).isEmpty)
  }

  @Test func updatedRowsSurviveReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try MutationFixture.make(dir, "persist.adsql")
    try db.prepare("UPDATE t SET qty = 999 WHERE id = 1").run()
    try db.prepare("DELETE FROM t WHERE id = 5").run()
    db.close()

    let reopened = try Database.open(at: dir.file("persist.adsql"))
    defer { reopened.close() }
    #expect(try reopened.prepare("SELECT qty FROM t WHERE id = 1").all()[0].values == [.integer(999)])
    #expect(try reopened.prepare("SELECT COUNT(*) FROM t").all()[0].values == [.integer(4)])
    _ = try reopened.verifyIntegrity(deep: true)
  }
}
