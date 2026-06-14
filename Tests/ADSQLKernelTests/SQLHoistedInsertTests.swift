import CSQLite
import Testing
import ADSQLTestSupport

@testable import ADSQLKernel

/// `Insert.hoisted` (RFC 0009 H3/R1) — the per-statement plan that hoists the
/// owned-index roster out of the row loop (cached per (txn, tableId)) and drops
/// ctx's alias to the relational state past conflict resolution so the write
/// loop's handle updates mutate in place (no per-row first-touch dictionary COW).
/// Every test asserts `hoisted ≡ standard ≡ SQLite` and keeps `verifyIntegrity
/// (deep:)` clean. The high-value cases exercise exactly what the slice touches:
/// the OR IGNORE/ABORT discard paths (which must leave ctx.relation intact, since
/// the alias is dropped only *after* them) and DDL mid-transaction (which must
/// invalidate the cached roster so a newly created index still gets maintained).
@Suite("SQL hoisted insert")
struct SQLHoistedInsertTests {
  // A three-index shape (mirrors the apple-docs bench): a unique key, a single-
  // column index, and a composite — so the roster has >1 entry and a stable order.
  static let ddl = [
    "CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT NOT NULL, framework TEXT, score INTEGER)",
    "CREATE UNIQUE INDEX uk ON t(k)",
    "CREATE INDEX ix_fw ON t(framework)",
    "CREATE INDEX ix_fw_score ON t(framework, score)",
  ]
  static let frameworks = ["swiftui", "foundation", "uikit", "metal"]

  static func openADSQL(
    _ dir: TempDir, _ name: String, _ insert: ExecutionOptions.Insert
  ) throws -> Database {
    let db = try Database.open(
      at: dir.file(name),
      options: DatabaseOptions(execution: ExecutionOptions(insert: insert)))
    for sql in ddl { try db.prepare(sql).run() }
    return db
  }

  static func mirror() throws -> SQLiteMirror {
    let m = SQLiteMirror()
    for sql in ddl { try m.exec(sql) }
    return m
  }

  static func rows(_ db: Database) throws -> [[Value]] {
    try db.prepare("SELECT id, k, framework, score FROM t ORDER BY id").all().map(\.values)
  }
  static func rows(_ m: SQLiteMirror) throws -> [[Value]] {
    try m.query("SELECT id, k, framework, score FROM t ORDER BY id")
  }

  /// Run the same statement against both ADSQL databases and the SQLite oracle.
  static func apply(_ sql: String, _ std: Database, _ hoi: Database, _ m: SQLiteMirror) throws {
    try std.prepare(sql).run()
    try hoi.prepare(sql).run()
    try m.exec(sql)
  }

  // MARK: - 1. Differential equivalence across a multi-index workload

  @Test func hoistedMatchesStandardAndSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let std = try Self.openADSQL(dir, "std.adsql", .standard)
    defer { std.close() }
    let hoi = try Self.openADSQL(dir, "hoi.adsql", .hoisted)
    defer { hoi.close() }
    let m = try Self.mirror()

    for i in 1...600 {
      let fw = i % 9 == 0 ? "NULL" : "'\(Self.frameworks[i % Self.frameworks.count])'"
      try Self.apply(
        "INSERT INTO t(k, framework, score) VALUES('k\(i)', \(fw), \(i % 5))", std, hoi, m)
    }
    #expect(try Self.rows(hoi) == Self.rows(m), "bulk multi-index")
    #expect(try Self.rows(hoi) == Self.rows(std))

    // OR REPLACE on the unique key (re-establishes ctx.relation around the nested
    // delete) and a composite-index-touching update of the replaced row.
    try Self.apply("INSERT OR REPLACE INTO t(id, k, framework, score) VALUES(1, 'k1', 'metal', 9)",
      std, hoi, m)
    try Self.apply("INSERT OR REPLACE INTO t(k, framework, score) VALUES('k2', 'uikit', 3)",
      std, hoi, m)
    #expect(try Self.rows(hoi) == Self.rows(m), "or replace")
    #expect(try Self.rows(hoi) == Self.rows(std))

    _ = try std.verifyIntegrity(deep: true)
    _ = try hoi.verifyIntegrity(deep: true)
  }

  // MARK: - 2. OR IGNORE discard must NOT reload stale state mid-transaction

  /// The COW-avoidance drops ctx's alias to `state` only *after* conflict
  /// resolution, so an ignored/aborted row leaves the prior ctx.relation intact.
  /// This interleaves real inserts with conflicting OR IGNORE rows inside ONE
  /// transaction: if the discard path wrongly nil-ed ctx.relation, the next row's
  /// `ensureState` would reload the (empty) committed snapshot and lose the
  /// in-transaction rows — so a count/contents divergence from SQLite catches it.
  @Test func hoistedOrIgnoreDiscardPreservesInTxnState() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let std = try Self.openADSQL(dir, "istd.adsql", .standard)
    defer { std.close() }
    let hoi = try Self.openADSQL(dir, "ihoi.adsql", .hoisted)
    defer { hoi.close() }
    let m = try Self.mirror()

    func batch(_ db: Database) throws {
      try db.transaction { (tx) throws(DBError) in
        for i in 1...10 {
          try tx.run("INSERT INTO t(k, framework, score) VALUES(?, ?, ?)",
            .text("k\(i)"), .text("swiftui"), .integer(Int64(i)))
        }
        // Three conflicts (k3/k5/k7 already inserted above) — each ignored.
        for i in [3, 5, 7] {
          try tx.run("INSERT OR IGNORE INTO t(k, framework, score) VALUES(?, ?, ?)",
            .text("k\(i)"), .text("metal"), .integer(99))
        }
        for i in 11...20 {
          try tx.run("INSERT INTO t(k, framework, score) VALUES(?, ?, ?)",
            .text("k\(i)"), .text("uikit"), .integer(Int64(i)))
        }
      }
    }
    try batch(std)
    try batch(hoi)
    try m.exec("BEGIN")
    for i in 1...10 { try m.exec("INSERT INTO t(k,framework,score) VALUES('k\(i)','swiftui',\(i))") }
    for i in [3, 5, 7] {
      try m.exec("INSERT OR IGNORE INTO t(k,framework,score) VALUES('k\(i)','metal',99)")
    }
    for i in 11...20 { try m.exec("INSERT INTO t(k,framework,score) VALUES('k\(i)','uikit',\(i))") }
    try m.exec("COMMIT")

    #expect(try Self.rows(hoi).count == 20, "all 20 real rows survive the ignored conflicts")
    #expect(try Self.rows(hoi) == Self.rows(m), "hoisted vs SQLite")
    #expect(try Self.rows(hoi) == Self.rows(std), "hoisted vs standard")
    _ = try hoi.verifyIntegrity(deep: true)
  }

  // MARK: - 3. DDL mid-transaction invalidates the cached roster

  /// A CREATE INDEX between two inserts in the same transaction changes the owned-
  /// index set. The hoisted roster is cached per (txn, tableId); if the cache were
  /// not invalidated, the post-DDL insert would use the stale roster and skip the
  /// new index → a missing index entry that `verifyIntegrity(deep:)` flags, and a
  /// lookup through the new index would miss the row.
  @Test func hoistedDDLMidTransactionInvalidatesRoster() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let hoi = try Self.openADSQL(dir, "ddl.adsql", .hoisted)
    defer { hoi.close() }

    try hoi.transaction { (tx) throws(DBError) in
      // First insert fills the roster cache (uk, ix_fw, ix_fw_score) for this txn.
      try tx.run("INSERT INTO t(k, framework, score) VALUES('a', 'swiftui', 1)")
      // New index on a column → must clear the cache.
      try tx.run("CREATE INDEX ix_score ON t(score)")
      // This row must be entered into ix_score too (re-derived roster).
      try tx.run("INSERT INTO t(k, framework, score) VALUES('b', 'metal', 1)")
      try tx.run("INSERT INTO t(k, framework, score) VALUES('c', 'uikit', 1)")
    }

    // deepCheck verifies the index⇄row bijection across EVERY index, so if the
    // post-DDL rows had skipped the re-derived `ix_score` it would flag the missing
    // entries. A plain ordered read is a contents sanity check on top.
    _ = try hoi.verifyIntegrity(deep: true)
    let all = try hoi.prepare("SELECT k FROM t WHERE score = 1 ORDER BY k").all().map(\.values)
    #expect(all == [[.text("a")], [.text("b")], [.text("c")]], "all score=1 rows present")
  }

  // MARK: - 4. Randomized fuzz: hoisted ≡ standard ≡ SQLite

  @Test func hoistedFuzzMatchesStandardAndSQLite() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let std = try Self.openADSQL(dir, "fstd.adsql", .standard)
    defer { std.close() }
    let hoi = try Self.openADSQL(dir, "fhoi.adsql", .hoisted)
    defer { hoi.close() }
    let m = try Self.mirror()

    var rng = SplitMix64(seed: 0xC0FF_EE42)
    var keyCounter = 0

    for _ in 0..<700 {
      let roll = rng.next() % 100
      let fw = Self.frameworks[Int(rng.next() % UInt64(Self.frameworks.count))]
      let score = Int(rng.next() % 6)
      if roll < 60 {
        keyCounter += 1
        try Self.apply(
          "INSERT INTO t(k, framework, score) VALUES('f\(keyCounter)', '\(fw)', \(score))",
          std, hoi, m)
      } else if roll < 75 {
        // OR IGNORE on a possibly-colliding existing key (drives the discard path).
        let pick = keyCounter == 0 ? 1 : Int(rng.next() % UInt64(keyCounter)) + 1
        try Self.apply(
          "INSERT OR IGNORE INTO t(k, framework, score) VALUES('f\(pick)', '\(fw)', \(score))",
          std, hoi, m)
      } else if roll < 88 {
        // OR REPLACE on a possibly-colliding existing key.
        let pick = keyCounter == 0 ? 1 : Int(rng.next() % UInt64(keyCounter)) + 1
        try Self.apply(
          "INSERT OR REPLACE INTO t(k, framework, score) VALUES('f\(pick)', '\(fw)', \(score))",
          std, hoi, m)
      } else {
        let ids = try Self.rows(m).map { $0[0] }
        guard let pick = ids.randomElement(using: &rng), case .integer(let id) = pick else { continue }
        try Self.apply("DELETE FROM t WHERE id = \(id)", std, hoi, m)
      }
    }

    #expect(try Self.rows(hoi) == Self.rows(m), "fuzz: hoisted vs SQLite")
    #expect(try Self.rows(hoi) == Self.rows(std), "fuzz: hoisted vs standard")
    _ = try std.verifyIntegrity(deep: true)
    _ = try hoi.verifyIntegrity(deep: true)
  }
}
