import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// `items(id PK, key UNIQUE NOT NULL, name, qty DEFAULT 0)` created in ADSQL
/// (relational API — SQL DDL lands in the next slice) and SQLite, so identical
/// INSERT SQL can be applied to both and the resulting table state compared.
private enum InsertFixture {
  static let definition = TableDefinition(
    "items",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("key", .text, notNull: true),
      ColumnDefinition("name", .text),
      ColumnDefinition("qty", .integer, defaultValue: .value(.integer(0))),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let sqliteDDL =
    "CREATE TABLE items(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT, qty INTEGER DEFAULT 0)"

  static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
    let db = try Database.open(at: dir.file(name))
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(definition)
      try txn.createIndex(IndexDefinition("u_key", on: "items", columns: ["key"], unique: true))
    }
    let mirror = SQLiteMirror()
    try mirror.exec(sqliteDDL)
    return (db, mirror)
  }

  static func state(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, key, name, qty FROM items ORDER BY id").all().map(\.values)
  }
  static func state(_ mirror: SQLiteMirror) throws -> [[Value]] {
    try mirror.query("SELECT id, key, name, qty FROM items ORDER BY id")
  }
}

@Suite("SQL INSERT")
struct SQLInsertTests {
  /// The same INSERT script run against both engines must leave identical
  /// table state.
  @Test func insertScriptMatchesSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try InsertFixture.make(dir, "insert.adsql")
    defer { db.close() }

    let statements = [
      "INSERT INTO items(id, key, name) VALUES(1, 'a', 'Alpha')",
      "INSERT INTO items(id, key, name) VALUES(2, 'b', 'Beta'), (3, 'c', 'Gamma')",
      "INSERT INTO items VALUES(4, 'd', 'Delta', 7)",
      "INSERT INTO items(id, key) VALUES(5, 'e')",  // qty defaults to 0
      "INSERT OR IGNORE INTO items(id, key, name) VALUES(6, 'a', 'dup')",  // key conflict → skipped
      "INSERT OR REPLACE INTO items(id, key, name) VALUES(99, 'b', 'Beta2')",  // replaces key 'b'
    ]
    for sql in statements {
      try db.prepare(sql).run()
      try mirror.exec(sql)
      #expect(try InsertFixture.state(db) == InsertFixture.state(mirror), "after: \(sql)")
    }
  }

  @Test func runResultReportsChangesAndRowid() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try InsertFixture.make(dir, "result.adsql")
    defer { db.close() }

    let single = try db.prepare("INSERT INTO items(id, key) VALUES(10, 'x')").run()
    #expect(single.changes == 1 && single.lastInsertRowid == 10)

    let multi = try db.prepare("INSERT INTO items(id, key) VALUES(11, 'y'), (12, 'z')").run()
    #expect(multi.changes == 2 && multi.lastInsertRowid == 12)

    let ignored = try db.prepare("INSERT OR IGNORE INTO items(id, key) VALUES(13, 'x')").run()
    #expect(ignored.changes == 0)
  }

  @Test func returningReadsInsertedRow() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try InsertFixture.make(dir, "returning.adsql")
    defer { db.close() }

    let rows = try db.prepare(
      "INSERT INTO items(id, key, name) VALUES(1, 'a', 'Alpha') RETURNING id, key, qty"
    ).all()
    #expect(rows.count == 1)
    #expect(rows[0].values == [.integer(1), .text("a"), .integer(0)])
    #expect(rows[0].columns == ["id", "key", "qty"])

    let star = try db.prepare(
      "INSERT INTO items(id, key) VALUES(2, 'b') RETURNING *"
    ).all()
    #expect(star[0].values == [.integer(2), .text("b"), .null, .integer(0)])
  }

  @Test func parameterizedInsert() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try InsertFixture.make(dir, "param.adsql")
    defer { db.close() }

    try db.prepare("INSERT INTO items(id, key, name) VALUES(?, ?, ?)")
      .run(.integer(1), .text("a"), .text("Alpha"))
    try mirror.exec("INSERT INTO items(id, key, name) VALUES(1, 'a', 'Alpha')")
    #expect(try InsertFixture.state(db) == InsertFixture.state(mirror))
  }

  @Test func insertConflictAbortThrows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try InsertFixture.make(dir, "abort.adsql")
    defer { db.close() }

    try db.prepare("INSERT INTO items(id, key) VALUES(1, 'a')").run()
    #expect(throws: DBError.self) {
      try db.prepare("INSERT INTO items(id, key) VALUES(2, 'a')").run()  // UNIQUE violation
    }
    // The aborted statement left no trace.
    #expect(try db.prepare("SELECT COUNT(*) FROM items").all()[0].values == [.integer(1)])
  }
}
