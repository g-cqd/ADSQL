import Dispatch
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private let docsDef = TableDefinition(
  "docs",
  columns: [
    ColumnDefinition("id", .integer, notNull: true),
    ColumnDefinition("key", .text, notNull: true),
    ColumnDefinition("title", .text, collation: .nocase),
    ColumnDefinition("score", .integer, defaultValue: .value(.integer(0))),
    ColumnDefinition("payload", .blob),
  ],
  primaryKey: .rowidAlias(column: "id", autoincrement: true))

private let extrasDef = TableDefinition(
  "extras",
  columns: [
    ColumnDefinition("name", .text),
    ColumnDefinition("val", .real),
  ])

private func setUpSchema(_ db: Database) throws {
  try db.writeSync { (txn) throws(DBError) in
    try txn.createTable(docsDef)
    try txn.createTable(extrasDef)
    try txn.createIndex(IndexDefinition("u_docs_key", on: "docs", columns: ["key"], unique: true))
    try txn.createIndex(IndexDefinition("i_docs_title", on: "docs", columns: ["title"]))
    try txn.createIndex(IndexDefinition("i_docs_score_title", on: "docs", columns: ["score", "title"]))
    try txn.createIndex(IndexDefinition("u_extras_val", on: "extras", columns: ["val"], unique: true))
  }
}

/// Compares the engine's visible state against the model: every table scan,
/// every index ordering, plus whole-file integrity.
private func verifyAgainstModel(_ db: Database, _ model: RelationalModelStore) throws {
  for tableName in model.tables.keys.sorted() {
    let engineRows = try db.read { (txn) throws(DBError) in
      try txn.withRowCursor(table: tableName) { (cursor) throws(DBError) in
        var out: [(Int64, [Value])] = []
        while let row = try cursor.next() {
          out.append((row.rowid, row.values))
        }
        return out
      }
    }
    let expected = model.sortedRows(tableName)
    #expect(engineRows.count == expected.count, "\(tableName) row count")
    for (got, want) in zip(engineRows, expected) {
      #expect(got.0 == want.rowid, "\(tableName) rowid order")
      #expect(got.1 == want.values, "\(tableName) rowid \(want.rowid) values")
    }
  }
  for indexName in model.indexes.keys.sorted() {
    let engineOrder = try db.read { (txn) throws(DBError) in
      try txn.withIndexCursor(index: indexName) { (cursor) throws(DBError) in
        var rowids: [Int64] = []
        while let row = try cursor.next() {
          rowids.append(row.rowid)
        }
        return rowids
      }
    }
    #expect(engineOrder == model.indexOrder(indexName), "index \(indexName) order")
  }
  _ = try db.verifyIntegrity(deep: true)
}

@Suite("Relation DML model tests")
struct RelationDMLModelTests {
  @Test(arguments: [UInt64(11), 222, 3333])
  func randomOpsMatchModel(seed: UInt64) throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("dml-\(seed).adsql"))
    defer { db.close() }
    try setUpSchema(db)
    var model = RelationalModelStore()
    model.createTable(docsDef)
    model.createTable(extrasDef)
    model.createIndex(IndexDefinition("u_docs_key", on: "docs", columns: ["key"], unique: true))
    model.createIndex(IndexDefinition("i_docs_title", on: "docs", columns: ["title"]))
    model.createIndex(IndexDefinition("i_docs_score_title", on: "docs", columns: ["score", "title"]))
    model.createIndex(IndexDefinition("u_extras_val", on: "extras", columns: ["val"], unique: true))

    var rng = SplitMix64(seed: seed)
    let policies: [ConflictPolicy] = [.abort, .ignore, .replace]

    for batch in 0..<16 {
      try db.writeSync { (txn) throws(DBError) in
        for _ in 0..<50 {
          switch rng.next() % 10 {
          case 0..<5: // insert into docs
            let policy = policies[Int(rng.next() % 3)]
            var values: [String: Value] = [
              "key": .text("k\(rng.next() % 60)"),
              "title": .text(RandomValues.string(&rng)),
            ]
            if rng.next() % 3 == 0 { values["score"] = .integer(Int64(rng.next() % 5)) }
            if rng.next() % 4 == 0 { values["payload"] = .blob(RandomValues.bytes(&rng, maxLength: 12)) }
            if rng.next() % 8 == 0 { values["id"] = .integer(Int64(rng.next() % 500) + 1) }
            let expected = model.insert(into: "docs", values, onConflict: policy)
            do throws(DBError) {
              let got = try txn.insert(into: "docs", values, onConflict: policy)
              switch expected {
              case .inserted(let rowid): #expect(got == rowid)
              case .ignored: #expect(got == nil)
              case .uniqueViolation: Issue.record("expected violation, got \(String(describing: got))")
              }
            } catch {
              guard case .uniqueViolation = error, expected == .uniqueViolation else {
                throw error
              }
            }
          case 5..<7: // insert into extras (nullable unique → NULL never conflicts)
            let value: Value = rng.next() % 3 == 0 ? .null : .real(Double(rng.next() % 40))
            let values: [String: Value] = ["name": .text("n\(rng.next() % 20)"), "val": value]
            let expected = model.insert(into: "extras", values, onConflict: .ignore)
            let got = try txn.insert(into: "extras", values, onConflict: .ignore)
            switch expected {
            case .inserted(let rowid): #expect(got == rowid)
            case .ignored: #expect(got == nil)
            case .uniqueViolation: Issue.record("ignore policy cannot violate")
            }
          case 7..<9: // update random docs row
            let target = Int64(rng.next() % 80) + 1
            var set: [String: Value] = [:]
            if rng.next() % 2 == 0 { set["title"] = .text(RandomValues.string(&rng)) }
            if rng.next() % 2 == 0 { set["score"] = .integer(Int64(rng.next() % 5)) }
            if rng.next() % 5 == 0 { set["key"] = .text("k\(rng.next() % 60)") }
            if set.isEmpty { set["score"] = .integer(9) }
            let expected = model.update("docs", rowid: target, set: set)
            do throws(DBError) {
              let got = try txn.update("docs", rowid: target, set: set)
              switch expected {
              case nil: #expect(!got)
              case .inserted: #expect(got)
              case .ignored: Issue.record("unreachable")
              case .uniqueViolation:
                Issue.record("expected update violation at rowid \(target)")
              }
            } catch {
              guard case .uniqueViolation = error, expected == .uniqueViolation else {
                throw error
              }
            }
          default: // delete random docs row
            let target = Int64(rng.next() % 100) + 1
            let expected = model.delete(from: "docs", rowid: target)
            let got = try txn.delete(from: "docs", rowid: target)
            #expect(got == expected)
          }
        }
      }
      if batch % 4 == 3 {
        try verifyAgainstModel(db, model)
      }
    }
    try verifyAgainstModel(db, model)

    // Survives reopen byte-for-byte.
    db.close()
    let reopened = try Database.open(at: dir.file("dml-\(seed).adsql"))
    defer { reopened.close() }
    try verifyAgainstModel(reopened, model)
  }
}

@Suite("Relation DML semantics")
struct RelationDMLSemanticsTests {
  func makeDB(_ dir: TempDir, _ name: String) throws -> Database {
    let db = try Database.open(at: dir.file(name))
    try setUpSchema(db)
    return db
  }

  @Test func defaultsAndValidation() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "val.adsql")
    defer { db.close() }

    let rowid = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("a"), "title": .text("T")])
    }
    let row = try db.read { (txn) throws(DBError) in try txn.row(in: "docs", rowid: rowid!) }
    #expect(row?.integer("score") == 0) // static default
    #expect(row?.integer("id") == rowid) // alias filled
    #expect(row?["payload"] == .null)

    #expect(throws: DBError.notNullViolation(table: "docs", column: "key")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["title": .text("x")])
      }
    }
    #expect(throws: DBError.typeMismatch(table: "docs", column: "score", expected: "INTEGER", got: "TEXT")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["key": .text("b"), "score": .text("high")])
      }
    }
    #expect(throws: DBError.noSuchColumn(table: "docs", column: "ghost")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["key": .text("c"), "ghost": .integer(1)])
      }
    }
    // NaN stores as NULL (and the unique index skips it).
    let r1 = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "extras", ["val": .real(.nan)])
    }
    let r2 = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "extras", ["val": .real(.nan)])
    }
    #expect(r1 != nil && r2 != nil)
    let stored = try db.read { (txn) throws(DBError) in
      try txn.row(in: "extras", rowid: r1!)?["val"]
    }
    #expect(stored == .null)

    // datetime('now') default has the SQLite shape.
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "stamped",
        columns: [
          ColumnDefinition("k", .integer),
          ColumnDefinition("at", .text, defaultValue: .datetimeNow),
        ]))
      _ = try txn.insert(into: "stamped", ["k": .integer(1)])
    }
    let at = try db.read { (txn) throws(DBError) in
      try txn.row(in: "stamped", rowid: 1)?.text("at")
    }
    #expect(at?.count == 19)
    #expect(at?.hasPrefix("20") == true)
  }

  @Test func conflictPolicies() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "conflict.adsql")
    defer { db.close() }

    let first = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("dup"), "title": .text("one")])
    }
    #expect(throws: DBError.uniqueViolation(table: "docs", index: "u_docs_key")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["key": .text("dup"), "title": .text("two")])
      }
    }
    let ignored = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("dup")], onConflict: .ignore)
    }
    #expect(ignored == nil)

    // REPLACE removes the old row and gets a fresh autoincrement rowid.
    let replaced = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("dup"), "title": .text("three")], onConflict: .replace)
    }
    #expect(replaced != nil && replaced != first)
    let survivors = try db.read { (txn) throws(DBError) in
      try txn.withIndexCursor(index: "u_docs_key", bounds: .prefix([.text("dup")])) {
        (cursor) throws(DBError) in
        var titles: [String] = []
        while let row = try cursor.next() { titles.append(row.text("title") ?? "") }
        return titles
      }
    }
    #expect(survivors == ["three"])

    // Explicit rowid collision under replace overwrites in place.
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.insert(
        into: "docs",
        ["id": .integer(replaced!), "key": .text("dup2"), "title": .text("four")],
        onConflict: .replace)
    }
    let after = try db.read { (txn) throws(DBError) in
      try txn.row(in: "docs", rowid: replaced!)?.text("key")
    }
    #expect(after == "dup2")
    _ = try db.verifyIntegrity()
  }

  @Test func nocaseUniqueAndScans() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("nocase.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "t", columns: [ColumnDefinition("name", .text, collation: .nocase)]))
      try txn.createIndex(IndexDefinition("u_name", on: "t", columns: ["name"], unique: true))
      _ = try txn.insert(into: "t", ["name": .text("Apple")])
    }
    #expect(throws: DBError.uniqueViolation(table: "t", index: "u_name")) {
      try db.writeSync { (txn) throws(DBError) in
        _ = try txn.insert(into: "t", ["name": .text("APPLE")])
      }
    }
    // Probe with different case finds the row.
    let hit = try db.read { (txn) throws(DBError) in
      try txn.firstRowid(index: "u_name", equals: [.text("aPPlE")])
    }
    #expect(hit == 1)
  }

  @Test func indexBounds() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "bounds.adsql")
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      for (i, key) in ["alpha", "beta", "betamax", "gamma", "delta"].enumerated() {
        _ = try txn.insert(into: "docs", [
          "key": .text(key), "title": .text(key), "score": .integer(Int64(i % 2)),
        ])
      }
    }
    func keys(_ bounds: IndexBounds, index: String = "u_docs_key") throws -> [String] {
      try db.read { (txn) throws(DBError) in
        try txn.withIndexCursor(index: index, bounds: bounds) { (cursor) throws(DBError) in
          var out: [String] = []
          while let row = try cursor.next() { out.append(row.text("key") ?? "") }
          return out
        }
      }
    }
    #expect(try keys(.all) == ["alpha", "beta", "betamax", "delta", "gamma"])
    #expect(try keys(.prefix([.text("beta")])) == ["beta"])
    #expect(try keys(.range(
      lower: [.text("beta")], upper: [.text("delta")], lowerOpen: false, upperOpen: false))
      == ["beta", "betamax", "delta"])
    #expect(try keys(.range(
      lower: [.text("beta")], upper: [.text("delta")], lowerOpen: true, upperOpen: true))
      == ["betamax"])
    #expect(try keys(.range(lower: [.text("gamma")], upper: nil, lowerOpen: false, upperOpen: false))
      == ["gamma"])
    // Composite index: leading-column prefix.
    let zeroScore = try db.read { (txn) throws(DBError) in
      try txn.withIndexCursor(index: "i_docs_score_title", bounds: .prefix([.integer(0)])) {
        (cursor) throws(DBError) in
        var out: [String] = []
        while let row = try cursor.next() { out.append(row.text("key") ?? "") }
        return out
      }
    }
    #expect(Set(zeroScore) == ["alpha", "betamax", "delta"])
  }

  @Test func backfillPopulatedTable() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "backfill.adsql")
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      for i in 0..<2000 {
        _ = try txn.insert(into: "docs", [
          "key": .text("bk-\(i)"), "title": .text("title \(i % 37)"),
          "score": .integer(Int64(i % 11)),
        ])
      }
    }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createIndex(IndexDefinition("i_backfill", on: "docs", columns: ["score"]))
    }
    let counted = try db.read { (txn) throws(DBError) in
      try txn.withIndexCursor(index: "i_backfill", bounds: .prefix([.integer(3)])) {
        (cursor) throws(DBError) in
        var n = 0
        while try cursor.next() != nil { n += 1 }
        return n
      }
    }
    #expect(counted == 2000 / 11 + (3 < 2000 % 11 ? 1 : 0))
    _ = try db.verifyIntegrity()

    // Unique backfill over duplicate data fails atomically.
    #expect(throws: DBError.uniqueViolation(table: "docs", index: "u_backfill_title")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.createIndex(
          IndexDefinition("u_backfill_title", on: "docs", columns: ["title"], unique: true))
      }
    }
    let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(schema.indexes["u_backfill_title"] == nil)
    _ = try db.verifyIntegrity()
  }

  @Test func writeTxnSeesOwnRows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "own.adsql")
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      let rowid = try txn.insert(into: "docs", ["key": .text("self"), "title": .text("me")])
      let visible = try txn.row(in: "docs", rowid: rowid!)
      guard visible?.text("key") == "self" else {
        throw DBError.integrityFailure("own write invisible")
      }
      let probe = try txn.firstRowid(index: "u_docs_key", equals: [.text("self")])
      guard probe == rowid else {
        throw DBError.integrityFailure("own index entry invisible")
      }
      _ = try txn.update("docs", rowid: rowid!, set: ["title": .text("updated")])
    }
    let title = try db.read { (txn) throws(DBError) in
      try txn.row(in: "docs", rowid: 1)?.text("title")
    }
    #expect(title == "updated")
  }

  @Test func autoincrementSurvivesDeleteAndReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("auto.adsql")
    do {
      let db = try makeDB(dir, "auto.adsql")
      let a = try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["key": .text("a")])
      }
      #expect(a == 1)
      try db.writeSync { (txn) throws(DBError) in _ = try txn.delete(from: "docs", rowid: 1) }
      let b = try db.writeSync { (txn) throws(DBError) in
        try txn.insert(into: "docs", ["key": .text("b")])
      }
      #expect(b == 2, "AUTOINCREMENT must not reuse the deleted max")
      db.close()
    }
    let db = try Database.open(at: path)
    defer { db.close() }
    let c = try db.writeSync { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("c")])
    }
    #expect(c == 3, "sequence must persist across reopen")
  }

  @Test func updateRules() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeDB(dir, "upd.adsql")
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.insert(into: "docs", ["key": .text("u1"), "title": .text("A")])
      _ = try txn.insert(into: "docs", ["key": .text("u2"), "title": .text("B")])
    }
    // Unique conflict on update aborts.
    #expect(throws: DBError.uniqueViolation(table: "docs", index: "u_docs_key")) {
      try db.writeSync { (txn) throws(DBError) in
        _ = try txn.update("docs", rowid: 2, set: ["key": .text("u1")])
      }
    }
    // Self-update of a unique column is fine.
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.update("docs", rowid: 2, set: ["key": .text("u2")])
    }
    // Rowid alias updates are rejected.
    #expect(throws: DBError.self) {
      try db.writeSync { (txn) throws(DBError) in
        _ = try txn.update("docs", rowid: 2, set: ["id": .integer(99)])
      }
    }
    // Missing rowid → false.
    let missing = try db.writeSync { (txn) throws(DBError) in
      try txn.update("docs", rowid: 404, set: ["title": .text("x")])
    }
    #expect(!missing)
    _ = try db.verifyIntegrity()
  }
}

@Suite("Relation DML group commit", .serialized)
struct RelationDMLGroupCommitTests {
  @Test func failingInsertRequestRollsBackAlone() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("gcr.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(docsDef)
      try txn.createIndex(IndexDefinition("u_docs_key", on: "docs", columns: ["key"], unique: true))
      _ = try txn.insert(into: "docs", ["key": .text("taken")])
    }

    let blocker = DispatchSemaphore(value: 0)
    let blockerTask = Task.detached {
      try? db.writeSync { (txn) throws(DBError) in
        try txn.put(Array("warm".utf8), [0])
        blocker.wait()
      }
    }
    async let good1: Int64? = db.write { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("g1")])
    }
    async let poisoned: Int64? = db.write { (txn) throws(DBError) in
      _ = try txn.insert(into: "docs", ["key": .text("ghost")])
      return try txn.insert(into: "docs", ["key": .text("taken")]) // throws
    }
    async let good2: Int64? = db.write { (txn) throws(DBError) in
      try txn.insert(into: "docs", ["key": .text("g2")])
    }
    blocker.signal()

    let r1 = try await good1
    do {
      _ = try await poisoned
      Issue.record("expected uniqueViolation")
    } catch {
      #expect((error as? DBError) == DBError.uniqueViolation(table: "docs", index: "u_docs_key"))
    }
    let r2 = try await good2
    _ = await blockerTask.value
    #expect(r1 != nil && r2 != nil)

    let keys = try db.read { (txn) throws(DBError) in
      try txn.withIndexCursor(index: "u_docs_key") { (cursor) throws(DBError) in
        var out: [String] = []
        while let row = try cursor.next() { out.append(row.text("key") ?? "") }
        return out
      }
    }
    #expect(keys == ["g1", "g2", "taken"], "ghost row leaked or neighbor lost: \(keys)")
    _ = try db.verifyIntegrity()
  }
}
