import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// `docs(id, framework, score)` for UNION/UNION ALL and json_each IN tests.
private enum CompoundFixture {
  static let columns = ["id", "framework", "score"]
  static let frameworks = ["UIKit", "SwiftUI", "Foundation"]

  static let definition = TableDefinition(
    "docs",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("framework", .text),
      ColumnDefinition("score", .integer),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))

  static let sqliteDDL =
    "CREATE TABLE docs(id INTEGER PRIMARY KEY, framework TEXT, score INTEGER)"

  static func rows() -> [[Value]] {
    var rows: [[Value]] = []
    for i in 1...20 {
      let framework: Value = (i % 8 == 0) ? .null : .text(frameworks[i % frameworks.count])
      let score: Value = (i % 6 == 0) ? .null : .integer(Int64(i % 4))
      rows.append([.integer(Int64(i)), framework, score])
    }
    return rows
  }

  static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
    let db = try Database.open(at: dir.file(name))
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
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

@Suite("SQL compounds and json_each")
struct SQLCompoundTests {
  // ORDER BY chosen so each result is a total order (distinct projected values
  // or disjoint arms with a unique id), making ordered comparison reliable.
  static let orderedQueries: [String] = [
    "SELECT framework FROM docs WHERE score >= 2 UNION SELECT framework FROM docs WHERE score <= 1 ORDER BY framework",
    "SELECT framework FROM docs UNION SELECT framework FROM docs ORDER BY framework",
    "SELECT framework FROM docs WHERE score >= 2 UNION SELECT framework FROM docs WHERE score <= 1 ORDER BY 1",
    "SELECT id, framework FROM docs WHERE score >= 3 UNION ALL SELECT id, framework FROM docs WHERE score <= 0 ORDER BY id",
    "SELECT framework FROM docs UNION SELECT framework FROM docs ORDER BY framework LIMIT 2",
    "SELECT framework FROM docs WHERE score = 0 UNION SELECT framework FROM docs WHERE score = 1 UNION ALL SELECT framework FROM docs WHERE framework IS NULL ORDER BY framework",
    "SELECT id FROM docs WHERE framework IN (SELECT value FROM json_each('[\"UIKit\",\"Combine\"]')) ORDER BY id",
    "SELECT id FROM docs WHERE score IN (SELECT value FROM json_each('[0,2]')) ORDER BY id",
    "SELECT id FROM docs WHERE framework NOT IN (SELECT value FROM json_each('[\"UIKit\"]')) AND framework IS NOT NULL ORDER BY id",
  ]

  @Test(arguments: orderedQueries)
  func orderedMatchesSQLite(_ sql: String) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try CompoundFixture.make(dir, "compound.adsql")
    defer { db.close() }
    let ours = try db.prepare(sql).all().map(\.values)
    let theirs = try mirror.query(sql)
    #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
  }

  // UNION ALL keeps duplicates; without a total order compare as a multiset.
  static let multisetQueries: [String] = [
    "SELECT score FROM docs WHERE framework = 'UIKit' UNION ALL SELECT score FROM docs WHERE framework = 'SwiftUI'",
    "SELECT framework FROM docs WHERE score >= 2 UNION ALL SELECT framework FROM docs WHERE score <= 1",
  ]

  @Test(arguments: multisetQueries)
  func multisetMatchesSQLite(_ sql: String) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try CompoundFixture.make(dir, "compound-ms.adsql")
    defer { db.close() }
    let ours = try db.prepare(sql).all().map(\.values)
    let theirs = try mirror.query(sql)
    #expect(rowsMatch(ours, theirs, ordered: false), "\(sql): adsql \(ours) vs sqlite \(theirs)")
  }

  @Test func mismatchedColumnCountRejected() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, _) = try CompoundFixture.make(dir, "mismatch.adsql")
    defer { db.close() }
    #expect(throws: DBError.self) {
      try db.prepare("SELECT id FROM docs UNION SELECT id, framework FROM docs").all()
    }
  }

  @Test func jsonEachParameterBound() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let (db, mirror) = try CompoundFixture.make(dir, "jsoneach.adsql")
    defer { db.close() }
    let sql = "SELECT id FROM docs WHERE framework IN (SELECT value FROM json_each($list)) ORDER BY id"
    let params: [String: Value] = ["list": .text("[\"SwiftUI\",\"Foundation\"]")]
    let ours = try db.prepare(sql).all(params).map(\.values)
    let theirs = try mirror.query(
      "SELECT id FROM docs WHERE framework IN (SELECT value FROM json_each(?)) ORDER BY id",
      [.text("[\"SwiftUI\",\"Foundation\"]")])
    #expect(rowsMatch(ours, theirs, ordered: true), "\(ours) vs \(theirs)")
  }
}
