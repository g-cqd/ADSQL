import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// M5 / F3c — the SQL `MATCH` surface. An FTS5 table drives the query (outer);
/// a JOIN on `base.id = fts.rowid` fetches the base rows, exactly the apple-docs
/// search shape. Boolean membership only (ranking is F4). The end-to-end results
/// are checked against a hand-derived oracle, and the matching-rowid *sets* are
/// checked against real SQLite FTS5 (when the linked sqlite3 has FTS5).
@Suite("FTS5 — F3c MATCH SQL surface")
struct FTSQueryTests {
  /// `documents_fts(title, body)` (porter) over a `documents(id, key)` base.
  /// rowid in the FTS table equals `documents.id`, so the join is `d.id =
  /// f.rowid`. Six docs give term / AND / OR / NOT / prefix / phrase / column
  /// coverage. Returns the opened DB (caller closes).
  private static let corpus: [(id: Int64, key: String, title: String, body: String)] = [
    (1, "doc/swift/intro", "swift programming", "the quick brown fox jumps"),
    (2, "doc/python/intro", "python guide", "quick start tutorial for beginners"),
    (3, "doc/swift/ref", "swift quick reference", "brown bag lunch notes"),
    (4, "doc/rust/intro", "rust programming guide", "systems programming language"),
    (5, "doc/swift/concurrency", "swift concurrency", "async await structured tasks"),
    (6, "doc/python/async", "python asyncio", "await coroutines and tasks"),
  ]

  private func fixture(_ dir: TempDir) throws -> Database {
    let db = try Database.open(at: dir.file("ftsquery.adsql"))
    try db.prepare("CREATE TABLE documents(id INTEGER PRIMARY KEY, key TEXT NOT NULL)").run()
    try db.prepare(
      "CREATE VIRTUAL TABLE documents_fts USING fts5(title, body, tokenize='porter unicode61')"
    ).run()
    for row in Self.corpus {
      try db.prepare("INSERT INTO documents(id, key) VALUES(?, ?)").run(.integer(row.id), .text(row.key))
      try db.prepare("INSERT INTO documents_fts(rowid, title, body) VALUES(?, ?, ?)").run(
        .integer(row.id), .text(row.title), .text(row.body))
    }
    return db
  }

  /// The target shape: FTS drives, JOIN fetches base rows, ORDER BY base key.
  private static let joinQuery = """
    SELECT d.id, d.key FROM documents_fts f JOIN documents d ON d.id = f.rowid
    WHERE f MATCH ? ORDER BY d.id
    """

  private func ids(_ db: Database, _ query: String) throws -> [Int64] {
    try db.prepare(Self.joinQuery).all(.text(query)).map { row in
      guard case .integer(let id) = row[0] else { return Int64(-1) }
      return id
    }
  }

  // MARK: - End-to-end membership through the join

  @Test func termAndBooleans() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    #expect(try ids(db, "swift") == [1, 3, 5])
    #expect(try ids(db, "quick") == [1, 2, 3])
    #expect(try ids(db, "swift AND quick") == [1, 3])
    #expect(try ids(db, "swift OR python") == [1, 2, 3, 5, 6])
    #expect(try ids(db, "programming NOT swift") == [4])
    #expect(try ids(db, "nonexistent").isEmpty)
  }

  @Test func prefixAndStemming() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // "programming" stems to "program"; prefix "prog*" reaches it (docs 1, 4).
    #expect(try ids(db, "prog*") == [1, 4])
    // The query term is stemmed too: "programming" → "program".
    #expect(try ids(db, "programming") == [1, 4])
    // "async"/"asyncio" tokens; prefix "asyn*" reaches both stems.
    #expect(try ids(db, "asyn*") == [5, 6])
  }

  @Test func phraseAndColumn() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // doc 1 body: "the quick brown fox …" → quick immediately precedes brown.
    #expect(try ids(db, "\"quick brown\"") == [1])
    #expect(try ids(db, "\"brown quick\"").isEmpty)
    // "swift" appears only in titles; "quick" in title for doc 3, body for 1, 2.
    #expect(try ids(db, "title:swift") == [1, 3, 5])
    #expect(try ids(db, "body:quick") == [1, 2])
    #expect(try ids(db, "title:quick") == [3])
  }

  @Test func limitAndProjection() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // LIMIT after the FTS-driven join + ORDER BY: first two swift docs.
    let rows = try db.prepare("""
      SELECT d.key FROM documents_fts f JOIN documents d ON d.id = f.rowid
      WHERE f MATCH 'swift' ORDER BY d.id LIMIT 2
      """).all().map(\.values)
    #expect(rows == [[.text("doc/swift/intro")], [.text("doc/swift/ref")]])
  }

  @Test func ftsLeadingTablePlanIsMatch() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    let plan = try db.prepare("SELECT rowid FROM documents_fts f WHERE f MATCH 'swift'").planDescription()
    #expect(plan.contains("MATCH"), "\(plan)")
  }

  @Test func standaloneFTSRowids() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // The FTS table alone yields its docids via `rowid`.
    let rows = try db.prepare(
      "SELECT rowid FROM documents_fts WHERE documents_fts MATCH 'swift' ORDER BY rowid"
    ).all().map(\.values)
    #expect(rows == [[.integer(1)], [.integer(3)], [.integer(5)]])
  }

  // MARK: - Errors

  @Test func matchOnNonFTSTableThrows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // MATCH against an ordinary table: the planner can't lower it to an FTS
    // source, so it survives into the WHERE and fails at evaluation with the
    // runtime "MATCH is only valid as a WHERE constraint on an FTS table".
    do {
      _ = try db.prepare("SELECT id FROM documents d WHERE d MATCH 'swift'").all()
      Issue.record("MATCH on a non-FTS table must fail")
    } catch {
      guard case .sqlRuntime = error else {
        Issue.record("expected sqlRuntime, got \(error)")
        return
      }
    }
  }

  @Test func bm25ParsesAsFunctionCall() throws {
    // bm25() is no longer rejected at parse time (F4b): it parses as an ordinary
    // function call and the binder rewrites it to the FTS `rank` score slot.
    let parsed = try SQLParser.parseOne("SELECT bm25(documents_fts) FROM documents_fts")
    guard case .select(let select) = parsed, case .expr(let expr, _, _) = select.columns[0],
      case .function(let name, _, _, _) = expr
    else {
      Issue.record("bm25() should parse as a function call, got \(parsed)")
      return
    }
    #expect(name == "BM25")
  }

  // MARK: - Differential gate vs SQLite FTS5

  /// True when the linked sqlite3 has FTS5 compiled in (creating an fts5 table
  /// succeeds). When false, the differential assertions are skipped (the
  /// hand-derived oracle above still covers correctness).
  private static func sqliteHasFTS5() -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
    defer { sqlite3_close_v2(db) }
    return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)", nil, nil, nil) == SQLITE_OK
  }

  /// Builds the same corpus in a SQLite FTS5 table (porter, so stems match).
  private func sqliteMirror() throws -> SQLiteMirror {
    let mirror = SQLiteMirror()
    try mirror.exec("CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
    for row in Self.corpus {
      try mirror.insertRow("fts", ["rowid", "title", "body"], [.integer(row.id), .text(row.title), .text(row.body)])
    }
    return mirror
  }

  @Test func matchingRowidSetsEqualSQLiteFTS5() throws {
    guard Self.sqliteHasFTS5() else {
      // Documented skip: the bundled sqlite3 lacks FTS5. The hand-derived
      // oracle tests above remain the correctness gate.
      return
    }
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    let mirror = try sqliteMirror()

    // AND / OR / NOT / prefix / phrase / column over the shared corpus.
    let queries = [
      "swift", "quick", "tasks", "programming", "guide",
      "swift AND quick", "swift OR python", "programming NOT swift",
      "quick AND brown", "tasks OR guide",
      "prog*", "asyn*", "swif*", "quic*",
      "\"quick brown\"", "\"systems programming\"", "\"await coroutines\"",
      "title:swift", "body:quick", "title:guide", "body:tasks",
      "swift AND (quick OR concurrency)",
    ]
    for query in queries {
      let ours = try db.prepare(
        "SELECT rowid FROM documents_fts f WHERE f MATCH ? ORDER BY rowid"
      ).all(.text(query)).map(\.values)
      let theirs = try mirror.query("SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY rowid", [.text(query)])
      #expect(rowsMatch(ours, theirs, ordered: true), "MATCH '\(query)': adsql \(ours) vs sqlite \(theirs)")
    }
  }
}
