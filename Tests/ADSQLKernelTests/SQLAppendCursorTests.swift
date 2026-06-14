import CSQLite
import Testing
import ADSQLTestSupport

@testable import ADSQLKernel

/// `Insert.appendCursor` (RFC 0009 H5) — the warm rightmost-leaf append fast path.
/// Every test asserts it is byte-identical to the proven `.standard` path AND to
/// SQLite, keeps `verifyIntegrity(deep:)` clean, and stays correct across leaf
/// splits, deletes (the rootPage cache invalidation), explicit rowids, OR REPLACE,
/// multi-transaction boundaries, single-txn rollback (the in-place-append undo),
/// crash-recovery (reopen), and randomized fuzz sequences.
@Suite("SQL appendCursor")
struct SQLAppendCursorTests {
  static let ddl = "CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT NOT NULL, v INTEGER)"

  static func openADSQL(
    _ dir: TempDir, _ name: String, _ insert: ExecutionOptions.Insert
  ) throws -> Database {
    let db = try Database.open(
      at: dir.file(name),
      options: DatabaseOptions(execution: ExecutionOptions(insert: insert)))
    try db.prepare(ddl).run()
    try db.prepare("CREATE UNIQUE INDEX uk ON t(k)").run()
    return db
  }

  static func mirror() throws -> SQLiteMirror {
    let m = SQLiteMirror()
    try m.exec(ddl)
    try m.exec("CREATE UNIQUE INDEX uk ON t(k)")
    return m
  }

  static func rows(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, k, v FROM t ORDER BY id").all().map(\.values)
  }
  static func rows(_ m: SQLiteMirror) throws -> [[Value]] {
    try m.query("SELECT id, k, v FROM t ORDER BY id")
  }

  /// Run the same statement against both ADSQL databases and the SQLite oracle.
  static func apply(_ sql: String, _ std: Database, _ app: Database, _ m: SQLiteMirror) throws {
    try std.prepare(sql).run()
    try app.prepare(sql).run()
    try m.exec(sql)
  }

  // MARK: - 1. Differential equivalence across workloads

  @Test func appendCursorMatchesStandardAndSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let std = try Self.openADSQL(dir, "std.adsql", .standard)
    defer { std.close() }
    let app = try Self.openADSQL(dir, "app.adsql", .appendCursor)
    defer { app.close() }
    let m = try Self.mirror()

    // Ascending auto-inserts that span several leaf splits (fast path + the
    // slow-path split that refreshes the cache).
    for i in 1...600 {
      try Self.apply("INSERT INTO t(k, v) VALUES('k\(i)', \(i % 17))", std, app, m)
    }
    #expect(try Self.rows(app) == Self.rows(m), "ascending bulk")
    #expect(try Self.rows(app) == Self.rows(std))

    // Explicit rowid far above the max → the next auto-insert must see the stale
    // cache (a non-append re-shadows the root) and fall through correctly.
    try Self.apply("INSERT INTO t(id, k, v) VALUES(100000, 'kx', 1)", std, app, m)
    try Self.apply("INSERT INTO t(k, v) VALUES('k601', 2)", std, app, m)  // auto → 100001
    #expect(try Self.rows(app) == Self.rows(m), "explicit then auto")

    // Delete the current max, then auto-insert → the rowid is reused (matches
    // SQLite); the delete re-shadows the root so the cache invalidates.
    try Self.apply("DELETE FROM t WHERE id = 100001", std, app, m)
    try Self.apply("INSERT INTO t(k, v) VALUES('k602', 3)", std, app, m)
    #expect(try Self.rows(app) == Self.rows(m), "delete-max then reuse")

    // OR REPLACE on the unique key.
    try Self.apply("INSERT OR REPLACE INTO t(id, k, v) VALUES(200000, 'k1', 99)", std, app, m)
    #expect(try Self.rows(app) == Self.rows(m), "or replace")
    #expect(try Self.rows(app) == Self.rows(std))

    // Both trees + the index⇄row bijection must be sound.
    _ = try std.verifyIntegrity(deep: true)
    _ = try app.verifyIntegrity(deep: true)
  }

  // MARK: - 2. Single-transaction rollback undoes in-place appends

  @Test func appendCursorRollbackUndoesAppends() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let app = try Self.openADSQL(dir, "rb.adsql", .appendCursor)
    defer { app.close() }

    for i in 1...50 {
      try app.prepare("INSERT INTO t(k, v) VALUES('k\(i)', \(i))").run()
    }
    let before = try Self.rows(app)

    // A write txn that appends 10 more rows then throws → must roll back entirely,
    // including the in-place appends (which route through ctx.shadow's undo log).
    do throws(DBError) {
      try app.writeSync { (txn) throws(DBError) in
        for i in 51...60 {
          _ = try txn.insertAssembled(
            into: "t", columnSlots: [1, 2], values: [.text("k\(i)"), .integer(Int64(i))])
        }
        throw DBError.sqlBind("forced rollback")
      }
    } catch {}

    #expect(try Self.rows(app) == before, "rolled-back appends must vanish")
    _ = try app.verifyIntegrity(deep: true)

    // A fresh auto-insert reuses rowid 51 (the rolled-back 51..60 are gone).
    try app.prepare("INSERT INTO t(k, v) VALUES('after', 0)").run()
    let after = try Self.rows(app)
    #expect(after.count == 51)
    #expect(after.last?[0] == .integer(51), "next rowid after rollback is 51")
    _ = try app.verifyIntegrity(deep: true)
  }

  // MARK: - 3. Group-commit rollback isolation (the in-place append's undo across requests)

  @Test func appendCursorGroupCommitRollbackIsolation() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let app = try Self.openADSQL(dir, "gc.adsql", .appendCursor)
    defer { app.close() }

    // Concurrent group-committed writers sharing one context: the good requests
    // append and commit; the poisoned request appends then throws and must roll
    // back ONLY its own delta (the shared-context in-place-append undo path).
    await withTaskGroup(of: Void.self) { group in
      for i in 1...8 {
        group.addTask {
          try? await app.write { (txn) throws(DBError) in
            _ = try txn.insertAssembled(
              into: "t", columnSlots: [1, 2], values: [.text("g\(i)"), .integer(Int64(i))])
          }
        }
      }
      group.addTask {
        try? await app.write { (txn) throws(DBError) in
          _ = try txn.insertAssembled(
            into: "t", columnSlots: [1, 2], values: [.text("poison"), .integer(-1)])
          throw DBError.sqlBind("forced rollback")
        }
      }
      await group.waitForAll()
    }

    let rows = try Self.rows(app)
    #expect(rows.count == 8, "8 committed appends, poison rolled back")
    #expect(!rows.contains { $0[1] == .text("poison") }, "poisoned append must not survive")
    _ = try app.verifyIntegrity(deep: true)
  }

  // MARK: - 4. Crash recovery: appends survive a reopen

  @Test func appendCursorSurvivesReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = "appendreopen.adsql"
    do {
      let app = try Self.openADSQL(dir, path, .appendCursor)
      // Several committed transactions of appends, spanning leaf splits.
      for batch in 0..<5 {
        try app.writeSync { (txn) throws(DBError) in
          for i in 0..<200 {
            let n = batch * 200 + i
            _ = try txn.insertAssembled(
              into: "t", columnSlots: [1, 2], values: [.text("k\(n)"), .integer(Int64(n))])
          }
        }
      }
      _ = try app.verifyIntegrity(deep: true)
      app.close()
    }
    // Fresh open from disk only.
    let reopened = try Database.open(at: dir.file(path))
    defer { reopened.close() }
    let rows = try Self.rows(reopened)
    #expect(rows.count == 1000, "all committed appends recovered")
    #expect(rows.first?[0] == .integer(1) && rows.last?[0] == .integer(1000))
    _ = try reopened.verifyIntegrity(deep: true)
  }

  // MARK: - 5. Randomized fuzz: appendCursor ≡ standard ≡ SQLite

  @Test func appendCursorFuzzMatchesStandardAndSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let std = try Self.openADSQL(dir, "fstd.adsql", .standard)
    defer { std.close() }
    let app = try Self.openADSQL(dir, "fapp.adsql", .appendCursor)
    defer { app.close() }
    let m = try Self.mirror()

    var rng = SplitMix64(seed: 0x5EED_F00D)
    var keyCounter = 0

    func currentMaxId() throws -> Int64 {
      let all = try Self.rows(m)
      guard let last = all.last, case .integer(let id) = last[0] else { return 0 }
      return id
    }

    for _ in 0..<700 {
      let roll = rng.next() % 100
      if roll < 68 {
        keyCounter += 1
        try Self.apply(
          "INSERT INTO t(k, v) VALUES('f\(keyCounter)', \(Int(rng.next() % 1000)))", std, app, m)
      } else if roll < 82 {
        // Explicit rowid just past the current max (guaranteed unused) — exercises
        // the explicit→putBytes path that re-shadows the root and so invalidates
        // the append cache for the following auto-insert.
        keyCounter += 1
        let id = try currentMaxId() + 1
        try Self.apply(
          "INSERT INTO t(id, k, v) VALUES(\(id), 'f\(keyCounter)', 7)", std, app, m)
      } else {
        // Delete an existing row chosen from the oracle (drives all three identically).
        let ids = try Self.rows(m).map { $0[0] }
        guard let pick = ids.randomElement(using: &rng), case .integer(let id) = pick else { continue }
        try Self.apply("DELETE FROM t WHERE id = \(id)", std, app, m)
      }
    }

    #expect(try Self.rows(app) == Self.rows(m), "fuzz: appendCursor vs SQLite")
    #expect(try Self.rows(app) == Self.rows(std), "fuzz: appendCursor vs standard")
    _ = try std.verifyIntegrity(deep: true)
    _ = try app.verifyIntegrity(deep: true)
  }
}
