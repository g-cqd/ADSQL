import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// INSERT … ON CONFLICT(target) DO UPDATE, compared against SQLite by applying
/// the same script to both and diffing the table.
@Suite("SQL upsert (ON CONFLICT DO UPDATE)")
struct SQLUpsertTests {
  private static let ddl =
    "CREATE TABLE kv(id INTEGER PRIMARY KEY, k TEXT UNIQUE, hits INTEGER, name TEXT)"

  private func build() throws -> (Database, SQLiteMirror, TempDir) {
    let dir = TempDir()
    let db = try Database.open(at: dir.file("upsert.adsql"))
    let mirror = SQLiteMirror()
    try db.prepare(Self.ddl).run()
    try mirror.exec(Self.ddl)
    return (db, mirror, dir)
  }

  private func state(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, k, hits, name FROM kv ORDER BY id").all().map(\.values)
  }
  private func state(_ m: SQLiteMirror) throws -> [[Value]] {
    try m.query("SELECT id, k, hits, name FROM kv ORDER BY id")
  }

  @Test func upsertScriptMatchesSQLite() throws {
    let (db, mirror, dir) = try build()
    defer { dir.cleanup(); db.close() }
    let statements = [
      "INSERT INTO kv(id, k, hits, name) VALUES(1, 'a', 1, 'Alpha')",
      // conflict on k='a' → bump hits, take excluded.name
      "INSERT INTO kv(id, k, hits, name) VALUES(2, 'a', 1, 'Beta') ON CONFLICT(k) DO UPDATE SET hits = hits + 1, name = excluded.name",
      // no conflict (k='b' new) → insert
      "INSERT INTO kv(id, k, hits, name) VALUES(3, 'b', 5, 'Gamma') ON CONFLICT(k) DO UPDATE SET hits = hits + excluded.hits",
      // conflict on k='b' → hits = existing + excluded
      "INSERT INTO kv(id, k, hits, name) VALUES(4, 'b', 5, 'Delta') ON CONFLICT(k) DO UPDATE SET hits = hits + excluded.hits",
      // conflict on the PK id=1 → update name only
      "INSERT INTO kv(id, k, hits, name) VALUES(1, 'zzz', 99, 'Zed') ON CONFLICT(id) DO UPDATE SET name = excluded.name",
      // DO NOTHING ≈ ignore
      "INSERT INTO kv(id, k, hits, name) VALUES(5, 'a', 0, 'dup') ON CONFLICT(k) DO NOTHING",
    ]
    for sql in statements {
      try db.prepare(sql).run()
      try mirror.exec(sql)
      #expect(try state(db) == state(mirror), "after: \(sql)")
    }
  }

  @Test func upsertRunResultAndReturning() throws {
    let (db, _, dir) = try build()
    defer { dir.cleanup(); db.close() }
    try db.prepare("INSERT INTO kv(id, k, hits) VALUES(1, 'a', 10)").run()

    // Conflict path returns the post-update row.
    let updated = try db.prepare(
      "INSERT INTO kv(id, k, hits) VALUES(2, 'a', 3) ON CONFLICT(k) DO UPDATE SET hits = hits + excluded.hits RETURNING id, hits"
    ).all()
    #expect(updated.map(\.values) == [[.integer(1), .integer(13)]])

    // Insert path returns the inserted row and reports lastInsertRowid.
    let inserted = try db.prepare(
      "INSERT INTO kv(id, k, hits) VALUES(7, 'b', 4) ON CONFLICT(k) DO UPDATE SET hits = 0 RETURNING id"
    ).all()
    #expect(inserted.map(\.values) == [[.integer(7)]])
    #expect(try db.prepare("SELECT COUNT(*) FROM kv").all()[0][0] == .integer(2))
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func upsertOnNonUniqueTargetThrows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("badtarget.adsql"))
    defer { db.close() }
    try db.prepare("CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT)").run()
    #expect(throws: DBError.self) {
      try db.prepare("INSERT INTO t(id, a) VALUES(1, 'x') ON CONFLICT(a) DO UPDATE SET a = 'y'").run()
    }
  }
}
