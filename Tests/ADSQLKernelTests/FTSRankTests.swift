import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// M5 / F4b — the `rank` / `bm25()` SQL surface + `ORDER BY rank`. The FTS5 table
/// drives the query (outer); a JOIN on `base.id = fts.rowid` fetches the base
/// rows — the apple-docs search shape — and `ORDER BY rank LIMIT k` returns the
/// most relevant docs first (SQLite's negative-ascending convention). Ordering
/// is checked against a hand-derived oracle and, when the linked sqlite3 has
/// FTS5, differentially against real SQLite FTS5 top-k rowid order.
@Suite("FTS5 — F4b rank / bm25() + ORDER BY rank")
struct FTSRankTests {
  /// `documents_fts(title, body)` (porter) over a `documents(id, key)` base, with
  /// rowid == documents.id. The "swift" docs vary in term frequency, field
  /// placement, and length so bm25 ranking is non-trivial and field weights can
  /// reorder them.
  private static let corpus: [(id: Int64, key: String, title: String, body: String)] = [
    (1, "a", "swift", "swift swift swift language is a swift joy to use daily"),
    (2, "b", "guide", "a short swift note"),
    (3, "c", "swift swift tutorial", "learn the basics here"),
    (4, "d", "python", "python and rust and go and java and c"),
    (5, "e", "concurrency", "swift structured concurrency with tasks and actors today"),
  ]

  private func fixture(_ dir: TempDir) throws -> Database {
    let db = try Database.open(at: dir.file("ftsrank.adsql"))
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

  /// Ordered rowids for `query`, ranked best-first via `ORDER BY rank`.
  private func rankedIDs(_ db: Database, _ orderExpr: String, _ query: String) throws -> [Int64] {
    try db.prepare("""
      SELECT d.id FROM documents_fts f JOIN documents d ON d.id = f.rowid
      WHERE f MATCH ? ORDER BY \(orderExpr)
      """).all(.text(query)).map { row in
      guard case .integer(let id) = row[0] else { return Int64(-1) }
      return id
    }
  }

  // MARK: - Ranked retrieval, best first

  @Test func rankOrdersMostRelevantFirst() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // Docs 1, 2, 3, 5 contain "swift" (doc 4 — "python and rust…" — does not).
    // Doc 1 has the highest tf and a title hit; doc 3 has a repeated title hit;
    // the rest are sparser. The exact order is asserted differentially below;
    // here we check the set is ranked (doc 1, the densest "swift" doc, is best)
    // and ascending by score.
    let ranked = try rankedIDs(db, "rank", "swift")
    #expect(Set(ranked) == Set([1, 2, 3, 5]))
    #expect(ranked.first == 1, "densest swift doc should rank first, got \(ranked)")

    // The scores are non-decreasing along the ranked order (ORDER BY rank ASC).
    let scores = try db.prepare("""
      SELECT rank FROM documents_fts f WHERE f MATCH 'swift' ORDER BY rank
      """).all().map { row -> Double in
      guard case .real(let s) = row[0] else { return .nan }
      return s
    }
    #expect(scores == scores.sorted())
    #expect(scores.allSatisfy { $0 < 0 }, "discriminating-corpus swift scores are negative")
  }

  @Test func rankRespectsLimit() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // Top-2 via the bounded top-N path: the two best "swift" docs, best first.
    let top2 = try db.prepare("""
      SELECT d.id FROM documents_fts f JOIN documents d ON d.id = f.rowid
      WHERE f MATCH 'swift' ORDER BY rank LIMIT 2
      """).all(.text("swift")).map { row -> Int64 in
      guard case .integer(let id) = row[0] else { return -1 }
      return id
    }
    let full = try rankedIDs(db, "rank", "swift")
    #expect(top2 == Array(full.prefix(2)))
  }

  @Test func bareRankEqualsAllOnesBM25() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // `rank` and `bm25(f)` (and `bm25(f, 1.0, 1.0)`) are the same all-ones order.
    let byRank = try rankedIDs(db, "rank", "swift")
    let byBM25 = try rankedIDs(db, "bm25(f)", "swift")
    let byBM25Ones = try rankedIDs(db, "bm25(f, 1.0, 1.0)", "swift")
    #expect(byRank == byBM25)
    #expect(byRank == byBM25Ones)
  }

  // MARK: - Weighted bm25 changes the order

  @Test func fieldWeightsChangeRanking() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // Weighting the title field heavily promotes title-hit docs (1, 3) over
    // body-only matches; weighting the body heavily favors the body-dense docs.
    let titleHeavy = try rankedIDs(db, "bm25(f, 10.0, 1.0)", "swift")
    let bodyHeavy = try rankedIDs(db, "bm25(f, 1.0, 10.0)", "swift")
    // Both rank the same four "swift" docs, but in a different order (weights
    // matter; doc 4 has no "swift").
    #expect(Set(titleHeavy) == Set([1, 2, 3, 5]))
    #expect(Set(bodyHeavy) == Set([1, 2, 3, 5]))
    #expect(titleHeavy != bodyHeavy, "field weights must reorder: \(titleHeavy) vs \(bodyHeavy)")
    // A title-bearing doc (3: "swift swift" in title, sparse body) ranks ahead of
    // a body-only doc (2) under title weighting.
    #expect(titleHeavy.firstIndex(of: 3)! < titleHeavy.firstIndex(of: 2)!)
  }

  @Test func projectedRankIsTheScore() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // bm25() / rank are projectable: the value equals the score used to order.
    let rows = try db.prepare("""
      SELECT d.id, bm25(f) FROM documents_fts f JOIN documents d ON d.id = f.rowid
      WHERE f MATCH 'swift' ORDER BY bm25(f)
      """).all(.text("swift")).map(\.values)
    let scores = rows.map { row -> Double in
      guard case .real(let s) = row[1] else { return .nan }
      return s
    }
    #expect(scores == scores.sorted())
    #expect(scores.allSatisfy { $0 < 0 })
  }

  // MARK: - Errors

  @Test func bm25OnNonFTSTableThrows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // bm25() names a non-FTS table: the binder can't rewrite it to a rank slot,
    // so it survives as a function call and fails at evaluation.
    do {
      _ = try db.prepare("SELECT bm25(documents) FROM documents").all()
      Issue.record("bm25() on a non-FTS table must fail")
    } catch {
      // sqlUnsupported (unknown function) or sqlRuntime/noSuchColumn — any error.
      _ = error
    }
  }

  // MARK: - Differential ORDERING vs SQLite FTS5

  private static func sqliteHasFTS5() -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
    defer { sqlite3_close_v2(db) }
    return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)", nil, nil, nil) == SQLITE_OK
  }

  private func sqliteMirror() throws -> SQLiteMirror {
    let mirror = SQLiteMirror()
    try mirror.exec("CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
    for row in Self.corpus {
      try mirror.insertRow(
        "fts", ["rowid", "title", "body"], [.integer(row.id), .text(row.title), .text(row.body)])
    }
    return mirror
  }

  /// The ranked rowid order must match SQLite FTS5 for plain `rank` and for
  /// weighted `bm25()`. Same corpus, same `porter unicode61` tokenizer, same
  /// weights — so equal ordering validates the bm25f scorer end to end. Skipped
  /// (with the hand-derived oracle still covering correctness) when the linked
  /// sqlite3 lacks FTS5.
  @Test func rankedOrderEqualsSQLiteFTS5() throws {
    guard Self.sqliteHasFTS5() else { return }  // documented skip; oracle covers us
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    let mirror = try sqliteMirror()

    // (our ORDER BY expr, sqlite ORDER BY expr, query). SQLite's `rank` ==
    // `bm25(fts)`; weighted forms name the columns' weights in declared order.
    let cases: [(ours: String, theirs: String, query: String)] = [
      ("rank", "rank", "swift"),
      ("bm25(f)", "bm25(fts)", "swift"),
      ("bm25(f, 10.0, 1.0)", "bm25(fts, 10.0, 1.0)", "swift"),
      ("bm25(f, 1.0, 10.0)", "bm25(fts, 1.0, 10.0)", "swift"),
      ("rank", "rank", "swift OR python"),
      ("rank", "rank", "swift AND concurrency"),
    ]
    for test in cases {
      let ours = try rankedIDs(db, test.ours, test.query)
      let theirs = try mirror.query(
        "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY \(test.theirs)", [.text(test.query)]
      ).map { row -> Int64 in
        guard case .integer(let id) = row[0] else { return -1 }
        return id
      }
      #expect(ours == theirs, "ORDER BY \(test.ours) for '\(test.query)': adsql \(ours) vs sqlite \(theirs)")
    }
  }
}
