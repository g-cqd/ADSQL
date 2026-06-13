import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// The zero-copy scan path hands inline values out as page spans but must fall
/// back to an assembled copy for overflow values (> Format.maxInlineCellSize,
/// 4064 B). These rows mix small (inline) and large (overflow) values so the
/// executor scan exercises both branches.
@Suite("SQL scan over overflow values")
struct SQLOverflowScanTests {
  private static let definition = TableDefinition(
    "big",
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("label", .text),
      ColumnDefinition("body", .text),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: false))

  private func build(_ dir: TempDir) throws -> Database {
    let db = try Database.open(at: dir.file("overflow.adsql"))
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(Self.definition)
      for i in 1...6 {
        // Even ids carry an 8 KB body (overflow); odd ids stay inline.
        let body = (i % 2 == 0) ? String(repeating: "x", count: 8192) : "small-\(i)"
        try txn.insert(into: "big", ["id": .integer(Int64(i)), "label": .text("L\(i)"), "body": .text(body)])
      }
    }
    return db
  }

  @Test func fullScanRoundTripsOverflow() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try build(dir)
    defer { db.close() }

    let rows = try db.prepare("SELECT id, label, LENGTH(body) AS n FROM big ORDER BY id").all()
    #expect(rows.count == 6)
    for (offset, row) in rows.enumerated() {
      let i = offset + 1
      #expect(row["id"] == .integer(Int64(i)))
      #expect(row["n"] == .integer(i % 2 == 0 ? 8192 : Int64("small-\(i)".count)))
    }
    // Project the overflow value itself and verify exact round-trip.
    let big = try db.prepare("SELECT body FROM big WHERE id = 4").all()
    #expect(big.first?[0] == .text(String(repeating: "x", count: 8192)))
  }

  @Test func filterDecodesOverflowRowsLazily() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try build(dir)
    defer { db.close() }

    // WHERE touches `label` (inline) on rows whose `body` is overflow; the
    // residual must not choke on the overflow record.
    let rows = try db.prepare("SELECT id FROM big WHERE label = 'L4'").all()
    #expect(rows.map(\.values) == [[.integer(4)]])
    _ = try db.verifyIntegrity(deep: true)
  }
}
