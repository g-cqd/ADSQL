import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// INSERT … SELECT, compared against SQLite by running the same script on both
/// and diffing the destination table.
@Suite("SQL INSERT … SELECT")
struct SQLInsertSelectTests {
  private static let schema = [
    "CREATE TABLE src(id INTEGER PRIMARY KEY, k TEXT, n INTEGER, fw TEXT)",
    "CREATE TABLE dst(id INTEGER PRIMARY KEY, label TEXT, n INTEGER)",
    "INSERT INTO src VALUES(1,'a',10,'UIKit'),(2,'b',20,'SwiftUI'),(3,'c',30,'UIKit'),(4,'d',5,'Combine')",
  ]

  private func build() throws -> (Database, SQLiteMirror, TempDir) {
    let dir = TempDir()
    let db = try Database.open(at: dir.file("insel.adsql"))
    let mirror = SQLiteMirror()
    for sql in Self.schema {
      try db.prepare(sql).run()
      try mirror.exec(sql)
    }
    return (db, mirror, dir)
  }

  private func dst(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, label, n FROM dst ORDER BY id").all().map(\.values)
  }
  private func dst(_ m: SQLiteMirror) throws -> [[Value]] {
    try m.query("SELECT id, label, n FROM dst ORDER BY id")
  }

  @Test func insertSelectMatchesSQLite() throws {
    let (db, mirror, dir) = try build()
    defer { dir.cleanup(); db.close() }
    let statements = [
      "INSERT INTO dst(id, label, n) SELECT id, k, n FROM src WHERE n >= 10",
      "INSERT INTO dst(label, n) SELECT 'fw:' || fw, n * 2 FROM src WHERE fw = 'UIKit' ORDER BY id",
      "INSERT INTO dst(id, label, n) SELECT id + 100, UPPER(k), n FROM src ORDER BY id LIMIT 2",
    ]
    for sql in statements {
      try db.prepare(sql).run()
      try mirror.exec(sql)
      #expect(try dst(db) == dst(mirror), "after: \(sql)")
    }
  }

  @Test func insertSelectRunResult() throws {
    let (db, mirror, dir) = try build()
    defer { dir.cleanup(); db.close() }
    let result = try db.prepare("INSERT INTO dst(id, label, n) SELECT id, k, n FROM src WHERE n > 8").run()
    #expect(result.changes == 3)  // ids 1,2,3 (n 10,20,30)
    try mirror.exec("INSERT INTO dst(id, label, n) SELECT id, k, n FROM src WHERE n > 8")
    #expect(try dst(db) == dst(mirror))
  }

  /// INSERT INTO t SELECT … FROM t must read the pre-insert snapshot
  /// (Halloween-safe), not loop over rows it is inserting.
  @Test func selfInsertIsHalloweenSafe() throws {
    let (db, _, dir) = try build()
    defer { dir.cleanup(); db.close() }
    try db.prepare("INSERT INTO dst(id, label, n) SELECT id, k, n FROM src").run()
    let before = try db.prepare("SELECT COUNT(*) FROM dst").all()[0][0]
    #expect(before == .integer(4))
    // Double the table by inserting its own rows (offset ids to avoid PK clash).
    try db.prepare("INSERT INTO dst(id, label, n) SELECT id + 1000, label, n FROM dst").run()
    #expect(try db.prepare("SELECT COUNT(*) FROM dst").all()[0][0] == .integer(8))
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func columnCountMismatchThrows() throws {
    let (db, _, dir) = try build()
    defer { dir.cleanup(); db.close() }
    #expect(throws: DBError.self) {
      try db.prepare("INSERT INTO dst(id, label) SELECT id, k, n FROM src").run()
    }
  }
}
