import ADSQLKernel
import ADSQLTestSupport
import Foundation
import Testing

/// Differential tests for the bounded top-N (ORDER BY + small LIMIT over an
/// unordered source) — exercising the zero-copy early-drop fast path (single
/// TEXT column) and its fallbacks (DESC, NOCASE, NULL, multi-column, non-text).
/// Sort values are unique (with at most one NULL) so ORDER BY … LIMIT is a total
/// order, making the row-by-row comparison against SQLite deterministic.
private enum TopNFixture {
  static let columns = ["id", "name", "tag"]

  static let definition = TableDefinition(
    "items",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("name", .text, notNull: true),       // BINARY, unique
      ColumnDefinition("tag", .text, collation: .nocase),   // NOCASE, unique, one NULL
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let sqliteDDL = """
    CREATE TABLE items(
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, tag TEXT COLLATE NOCASE);
    """

  // Mixed-case, unique-under-NOCASE — binary order (capitals first) differs from
  // NOCASE order, so these queries actually exercise the fold.
  static let tags = [
    "apple", "Banana", "Cherry", "date", "Elderberry", "fig",
    "Grape", "honeydew", "Kiwi", "Lemon", "Mango", "nectarine",
  ]

  static func rows() -> [[Value]] {
    (1...12).map { i in
      let name = Value.text(String(format: "n%02d", (i * 7) % 12))  // unique, not rowid order
      let tag: Value = i == 6 ? .null : .text(tags[i - 1])
      return [.integer(Int64(i)), name, tag]
    }
  }

  static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
    let db = try Database.open(at: dir.file(name))
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
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

@Suite("SQL bounded top-N")
struct SQLSearchTopNTests {
  static let queries: [String] = [
    "SELECT id, name FROM items ORDER BY name LIMIT 4",          // BINARY fast path, ASC
    "SELECT id, name FROM items ORDER BY name DESC LIMIT 4",     // BINARY DESC
    "SELECT id, name FROM items ORDER BY name LIMIT 100",        // LIMIT > rows (drops nothing)
    "SELECT id, tag FROM items ORDER BY tag LIMIT 4",            // NOCASE fast path, NULL first
    "SELECT id, tag FROM items ORDER BY tag DESC LIMIT 4",       // NOCASE DESC, NULL last
    "SELECT id, tag FROM items WHERE id <> 6 ORDER BY tag LIMIT 5",  // NOCASE, no NULL
    "SELECT id, name FROM items ORDER BY name LIMIT 3 OFFSET 2", // OFFSET into the top-N
    "SELECT id, name FROM items ORDER BY name, id LIMIT 4",      // multi-column → Value fallback
    "SELECT id FROM items ORDER BY id LIMIT 4",                  // INTEGER sort → fallback
  ]

  @Test(arguments: queries)
  func matchesSQLite(_ sql: String) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try TopNFixture.make(dir, "topn.adsql")
    defer { db.close() }

    let ours = try db.prepare(sql).all().map(\.values)
    let theirs = try mirror.query(sql)
    #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
  }
}
