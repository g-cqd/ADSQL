import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// M5 / F2b — self-contained FTS index build + maintenance through the SQL write
/// API. Inspection uses the internal read helpers (the SQL MATCH query is F3).
@Suite("FTS5 — F2b index build + maintenance")
struct FTSIndexTests {
  private func run(_ db: Database, _ sql: String) throws { try db.prepare(sql).run() }

  /// `term` after porter stemming, as bytes.
  private func term(_ s: String) -> [UInt8] { Array(s.utf8) }

  private func makeDocsTable(_ db: Database) throws {
    try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
    try run(db, "INSERT INTO fts(rowid, title, body) VALUES(10, 'Swift Running', 'the cats are running fast')")
    try run(db, "INSERT INTO fts(rowid, title, body) VALUES(20, 'Python', 'snakes slither')")
    try run(db, "INSERT INTO fts(rowid, title, body) VALUES(30, 'Running shoes', 'fast running')")
  }

  @Test func buildsPostingsDfAndStats() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("fts.adsql"))
    defer { db.close() }
    try makeDocsTable(db)

    try db.writeSync { (txn) throws(DBError) in
      // "running"/"Running" stem to "run": docs 10 and 30, in docid order.
      let run = try txn.ftsPostings("fts", term: term("run"))
      #expect(run?.map(\.docid) == [10, 30])
      #expect(run?[0].fieldTFs == [1, 1])  // title + body each once in doc 10
      #expect(try txn.ftsDocumentFrequency("fts", term: term("run")) == 2)

      // "swift" only in doc 10's title.
      #expect(try txn.ftsPostings("fts", term: term("swift"))?.map(\.docid) == [10])

      let global = try txn.ftsGlobalStats("fts")
      #expect(global.docCount == 3)
      // doc 10 lengths: title "Swift Running" = 2 tokens, body = 5 tokens.
      #expect(try txn.ftsDocStats("fts", docid: 10)?.fieldLengths == [2, 5])
    }
  }

  @Test func deleteUpdatesIndexAndPersists() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("ftsdel.adsql")
    do {
      let db = try Database.open(at: path)
      defer { db.close() }
      try makeDocsTable(db)
      try run(db, "DELETE FROM fts WHERE rowid = 10")

      try db.writeSync { (txn) throws(DBError) in
        #expect(try txn.ftsPostings("fts", term: term("run"))?.map(\.docid) == [30])
        #expect(try txn.ftsDocumentFrequency("fts", term: term("run")) == 1)
        // "swift" was unique to doc 10 → term gone entirely.
        #expect(try txn.ftsPostings("fts", term: term("swift")) == nil)
        #expect(try txn.ftsGlobalStats("fts").docCount == 2)
        #expect(try txn.ftsDocStats("fts", docid: 10) == nil)
      }
    }
    // Reopen: the index survives.
    let reopened = try Database.open(at: path)
    defer { reopened.close() }
    try reopened.writeSync { (txn) throws(DBError) in
      #expect(try txn.ftsPostings("fts", term: term("run"))?.map(\.docid) == [30])
      #expect(try txn.ftsGlobalStats("fts").docCount == 2)
    }
  }

  @Test func autoRowidIncrements() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ftsauto.adsql"))
    defer { db.close() }
    try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body)")
    try run(db, "INSERT INTO fts(body) VALUES('alpha')")
    try run(db, "INSERT INTO fts(body) VALUES('beta')")
    try run(db, "INSERT INTO fts(body) VALUES('gamma')")
    try db.writeSync { (txn) throws(DBError) in
      #expect(try txn.ftsPostings("fts", term: term("alpha"))?.map(\.docid) == [1])
      #expect(try txn.ftsPostings("fts", term: term("beta"))?.map(\.docid) == [2])
      #expect(try txn.ftsPostings("fts", term: term("gamma"))?.map(\.docid) == [3])
    }
  }

  @Test func rejectsDuplicateDocidAndUnsupportedShapes() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ftsrej.adsql"))
    defer { db.close() }
    try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title)")
    try run(db, "INSERT INTO fts(rowid, title) VALUES(5, 'x')")
    #expect(throws: DBError.self) { try run(db, "INSERT INTO fts(rowid, title) VALUES(5, 'y')") }
    // DELETE must be by rowid; a column predicate is unsupported.
    #expect(throws: DBError.self) { try run(db, "DELETE FROM fts WHERE title = 'x'") }
    // RETURNING on an FTS table is rejected.
    #expect(throws: DBError.self) {
      try run(db, "INSERT INTO fts(rowid, title) VALUES(6, 'z') RETURNING rowid")
    }
  }
}
