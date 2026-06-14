import ADSQL
import CSQLite
import Darwin
import Foundation

/// SQL-vs-SQL benchmark on the apple-docs `documents` shape: the same DDL,
/// batched INSERT, point SELECT by unique key, and filtered search-shaped
/// SELECT issued through each engine's SQL surface — re-measuring the M3
/// scan/insert gaps now that they flow through lazy rows and the planner.
enum SQLScenario {
  static let frameworks = ["swiftui", "foundation", "uikit", "appkit", "metal", "swift"]
  static let kinds = ["symbol", "article", "collection", "sample"]

  static let ddl = [
    """
    CREATE TABLE documents(
      id INTEGER PRIMARY KEY, key TEXT NOT NULL, title TEXT NOT NULL,
      framework TEXT, kind TEXT)
    """,
    "CREATE UNIQUE INDEX u_documents_key ON documents(key)",
    "CREATE INDEX i_documents_framework ON documents(framework)",
    "CREATE INDEX i_documents_fw_kind ON documents(framework, kind)",
  ]

  static func key(_ i: Int) -> String { "documentation/fw\(i % 6)/symbol-\(i)" }

  static func run(_ engine: String, dir: String, config: BenchConfig) throws {
    let rows = min(config.rows, 200_000)
    let path = "\(dir)/sql-\(engine).db"
    for suffix in ["", "-wal", "-shm", "-lock"] { unlink(path + suffix) }
    if engine == "adsql" {
      try runADSQL(path: path, rows: rows, config: config)
    } else {
      try runSQLite(path: path, rows: rows, config: config)
    }
  }

  // MARK: - ADSQL (SQL surface)

  static func runADSQL(path: String, rows: Int, config: BenchConfig) throws {
    let db = try Database.open(
      at: path,
      options: DatabaseOptions(
        durability: .none, maxMapSize: 32 << 30,
        execution: ExecutionOptions(
          evaluator: config.evaluator, join: config.joinStrategy, insert: config.insertStrategy)))
    defer { db.close() }
    for sql in ddl { try db.prepare(sql).run() }

    let insertStart = nowNanos()
    var inserted = 0
    while inserted < rows {
      let batchEnd = min(inserted + 512, rows)
      let lower = inserted
      try db.transaction { (tx) throws(DBError) in
        for i in lower..<batchEnd {
          try tx.run(
            "INSERT INTO documents(key, title, framework, kind) VALUES(?, ?, ?, ?)",
            .text(key(i)), .text("Symbol \(i) Overview"),
            .text(frameworks[i % frameworks.count]), .text(kinds[i % kinds.count]))
        }
      }
      inserted = batchEnd
    }
    print("  [adsql] sql insert      \(formatRate(rows, nowNanos() - insertStart)) rows/s (3 indexes)")

    var rng = BenchRNG(seed: 17)
    let byKey = try db.prepare("SELECT id, title FROM documents WHERE key = ?")
    var keyHist = LatencyHistogram()
    keyHist.reserve(config.pointGets)
    for _ in 0..<config.pointGets {
      let target = SQLScenario.key(Int(rng.next() % UInt64(rows)))
      let start = nowNanos()
      let result = try byKey.all(.text(target))
      keyHist.record(nowNanos() - start)
      precondition(result.count == 1)
    }
    print("  [adsql] sql key select  \(keyHist.summary())")

    let search = try db.prepare(
      "SELECT id, key FROM documents WHERE framework = ? AND kind = ? ORDER BY key LIMIT 20")
    var searchHist = LatencyHistogram()
    searchHist.reserve(config.pointGets)
    for _ in 0..<config.pointGets {
      let framework = frameworks[Int(rng.next() % UInt64(frameworks.count))]
      let kind = kinds[Int(rng.next() % UInt64(kinds.count))]
      let start = nowNanos()
      let result = try search.all(.text(framework), .text(kind))
      searchHist.record(nowNanos() - start)
      precondition(result.count <= 20)
    }
    print("  [adsql] sql search      \(searchHist.summary())")

    // Duplicate-heavy DISTINCT: ~12 distinct (framework, kind) pairs out of all
    // rows — the O(n^2) dedup's worst case.
    let distinct = try db.prepare("SELECT DISTINCT framework, kind FROM documents")
    var distinctHist = LatencyHistogram()
    for _ in 0..<20 {
      let start = nowNanos()
      let result = try distinct.all()
      distinctHist.record(nowNanos() - start)
      precondition(result.count > 0 && result.count <= 24)
    }
    print("  [adsql] sql distinct    \(distinctHist.summary())")

    // Indexed equi-join: each outer row probes the unique-key index for its
    // match (index-nested-loop). The unindexed O(M·N) baseline is unrunnable
    // at this scale.
    let join = try db.prepare(
      "SELECT COUNT(*) FROM documents a JOIN documents b ON b.key = a.key")
    var joinHist = LatencyHistogram()
    for _ in 0..<10 {
      let start = nowNanos()
      let result = try join.all()
      joinHist.record(nowNanos() - start)
      precondition(result[0].values == [.integer(Int64(rows))])
    }
    print("  [adsql] sql join        \(joinHist.summary())")
  }

  // MARK: - SQLite (SQL surface)

  static func runSQLite(path: String, rows: Int, config: BenchConfig) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
      == SQLITE_OK
    else { throw SQLiteError.code(1, "open") }
    let db = handle
    defer { sqlite3_close_v2(db) }
    func exec(_ sql: String) throws {
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteError.code(sqlite3_errcode(db), sql)
      }
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    try exec("PRAGMA journal_mode=WAL")
    try exec("PRAGMA synchronous=OFF")
    try exec("PRAGMA cache_size=-64000")
    try exec("PRAGMA mmap_size=10737418240")
    for sql in ddl { try exec(sql) }

    var insert: OpaquePointer?
    sqlite3_prepare_v3(
      db, "INSERT INTO documents(key, title, framework, kind) VALUES(?1, ?2, ?3, ?4)",
      -1, UInt32(SQLITE_PREPARE_PERSISTENT), &insert, nil)
    defer { sqlite3_finalize(insert) }

    let insertStart = nowNanos()
    var inserted = 0
    while inserted < rows {
      let batchEnd = min(inserted + 512, rows)
      try exec("BEGIN IMMEDIATE")
      for i in inserted..<batchEnd {
        sqlite3_reset(insert)
        sqlite3_bind_text(insert, 1, key(i), -1, transient)
        sqlite3_bind_text(insert, 2, "Symbol \(i) Overview", -1, transient)
        sqlite3_bind_text(insert, 3, frameworks[i % frameworks.count], -1, transient)
        sqlite3_bind_text(insert, 4, kinds[i % kinds.count], -1, transient)
        guard sqlite3_step(insert) == SQLITE_DONE else {
          throw SQLiteError.code(sqlite3_errcode(db), "insert")
        }
      }
      try exec("COMMIT")
      inserted = batchEnd
    }
    print("  [sqlite] sql insert      \(formatRate(rows, nowNanos() - insertStart)) rows/s (3 indexes)")

    var rng = BenchRNG(seed: 17)
    var byKey: OpaquePointer?
    sqlite3_prepare_v3(
      db, "SELECT id, title FROM documents WHERE key = ?1",
      -1, UInt32(SQLITE_PREPARE_PERSISTENT), &byKey, nil)
    defer { sqlite3_finalize(byKey) }
    var keyHist = LatencyHistogram()
    keyHist.reserve(config.pointGets)
    for _ in 0..<config.pointGets {
      let target = SQLScenario.key(Int(rng.next() % UInt64(rows)))
      let start = nowNanos()
      sqlite3_reset(byKey)
      sqlite3_bind_text(byKey, 1, target, -1, transient)
      precondition(sqlite3_step(byKey) == SQLITE_ROW)
      keyHist.record(nowNanos() - start)
    }
    print("  [sqlite] sql key select  \(keyHist.summary())")

    var search: OpaquePointer?
    sqlite3_prepare_v3(
      db, "SELECT id, key FROM documents WHERE framework = ?1 AND kind = ?2 ORDER BY key LIMIT 20",
      -1, UInt32(SQLITE_PREPARE_PERSISTENT), &search, nil)
    defer { sqlite3_finalize(search) }
    var searchHist = LatencyHistogram()
    searchHist.reserve(config.pointGets)
    for _ in 0..<config.pointGets {
      let framework = frameworks[Int(rng.next() % UInt64(frameworks.count))]
      let kind = kinds[Int(rng.next() % UInt64(kinds.count))]
      let start = nowNanos()
      sqlite3_reset(search)
      sqlite3_bind_text(search, 1, framework, -1, transient)
      sqlite3_bind_text(search, 2, kind, -1, transient)
      while sqlite3_step(search) == SQLITE_ROW {}
      searchHist.record(nowNanos() - start)
    }
    print("  [sqlite] sql search      \(searchHist.summary())")

    var distinct: OpaquePointer?
    sqlite3_prepare_v3(
      db, "SELECT DISTINCT framework, kind FROM documents",
      -1, UInt32(SQLITE_PREPARE_PERSISTENT), &distinct, nil)
    defer { sqlite3_finalize(distinct) }
    var distinctHist = LatencyHistogram()
    for _ in 0..<20 {
      let start = nowNanos()
      sqlite3_reset(distinct)
      while sqlite3_step(distinct) == SQLITE_ROW {}
      distinctHist.record(nowNanos() - start)
    }
    print("  [sqlite] sql distinct    \(distinctHist.summary())")

    var join: OpaquePointer?
    sqlite3_prepare_v3(
      db, "SELECT COUNT(*) FROM documents a JOIN documents b ON b.key = a.key",
      -1, UInt32(SQLITE_PREPARE_PERSISTENT), &join, nil)
    defer { sqlite3_finalize(join) }
    var joinHist = LatencyHistogram()
    for _ in 0..<10 {
      let start = nowNanos()
      sqlite3_reset(join)
      while sqlite3_step(join) == SQLITE_ROW {}
      joinHist.record(nowNanos() - start)
    }
    print("  [sqlite] sql join        \(joinHist.summary())")
  }
}
