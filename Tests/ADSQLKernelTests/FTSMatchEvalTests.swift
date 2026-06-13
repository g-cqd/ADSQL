import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// M5 / F3b — boolean MATCH evaluation over the F2 index (membership; ranking
/// is F4). Driven through `WriteTxn.ftsMatch`, which parses (F3a) + evaluates.
@Suite("FTS5 — F3b boolean MATCH evaluation")
struct FTSMatchEvalTests {
  /// A 3-doc fixture; returns the opened DB (caller closes).
  private func fixture(_ dir: TempDir) throws -> Database {
    let db = try Database.open(at: dir.file("ftsmatch.adsql"))
    try db.prepare("CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
      .run()
    try db.prepare("INSERT INTO fts(rowid, title, body) VALUES(1, 'swift programming', 'the quick brown fox')").run()
    try db.prepare("INSERT INTO fts(rowid, title, body) VALUES(2, 'python guide', 'quick start tutorial')").run()
    try db.prepare("INSERT INTO fts(rowid, title, body) VALUES(3, 'swift quick reference', 'brown bag lunch')").run()
    return db
  }

  private func match(_ db: Database, _ query: String) throws -> [Int64] {
    try db.writeSync { (txn) throws(DBError) in try txn.ftsMatch("fts", query) }
  }

  @Test func termsAndBooleans() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    #expect(try match(db, "swift") == [1, 3])
    #expect(try match(db, "quick") == [1, 2, 3])
    #expect(try match(db, "swift AND quick") == [1, 3])
    #expect(try match(db, "swift OR python") == [1, 2, 3])
    #expect(try match(db, "quick NOT swift") == [2])
    #expect(try match(db, "nonexistent").isEmpty)
  }

  @Test func prefixAndStemming() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // "programming" stems to "program"; prefix "prog*" reaches it.
    #expect(try match(db, "prog*") == [1])
    // The query term is stemmed too: "programming" → "program".
    #expect(try match(db, "programming") == [1])
    #expect(try match(db, "swif*") == [1, 3])
  }

  @Test func phraseAdjacency() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // doc 1 body: "the quick brown fox" → quick immediately precedes brown.
    #expect(try match(db, "\"quick brown\"") == [1])
    // Reversed order is not adjacent anywhere.
    #expect(try match(db, "\"brown quick\"").isEmpty)
  }

  @Test func columnFilters() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try fixture(dir)
    defer { db.close() }
    // "swift" appears only in titles.
    #expect(try match(db, "title:swift") == [1, 3])
    // doc 3 has "quick" in its title, not its body → excluded by body filter.
    #expect(try match(db, "body:quick") == [1, 2])
  }
}
