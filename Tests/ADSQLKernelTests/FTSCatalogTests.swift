import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private func parse(_ sql: String) throws -> SQLStatementAST {
  try SQLParser.parseOne(sql)
}

/// M5 / F0 — `CREATE VIRTUAL TABLE … USING fts5(…)` parsing and the catalog FTS
/// record (config + three owned trees) round-tripping through disk. No query or
/// indexing yet — those arrive in F1–F4.
@Suite("FTS5 — F0 (parse + catalog record)")
struct FTSCatalogTests {
  @Test func parsesSelfContainedAndExternalShapes() throws {
    // self-contained + `porter unicode61` + a column named `key` (a keyword).
    guard case .createVirtualTable(let docs) = try parse("""
      CREATE VIRTUAL TABLE documents_fts USING fts5(
        title, abstract, declaration, headings, key, tokenize='porter unicode61')
      """) else { Issue.record("not createVirtualTable"); return }
    #expect(docs.definition.columns == ["title", "abstract", "declaration", "headings", "key"])
    #expect(docs.definition.tokenize == ["porter", "unicode61"])
    #expect(docs.definition.content == .selfContained)
    #expect(docs.definition.detail == .full)
    #expect(docs.definition.columnSize)

    // external content (content + content_rowid) + trigram tokenizer args.
    guard case .createVirtualTable(let trig) = try parse("""
      CREATE VIRTUAL TABLE documents_trigram USING fts5(
        title, content='documents', content_rowid='id', tokenize='trigram case_sensitive 0')
      """) else { Issue.record("not createVirtualTable"); return }
    #expect(trig.definition.columns == ["title"])
    #expect(trig.definition.tokenize == ["trigram", "case_sensitive", "0"])
    #expect(trig.definition.content == .external(table: "documents", rowid: "id"))
  }

  @Test func parsesContentlessAndPrefixShapes() throws {
    // contentless + contentless_delete.
    guard case .createVirtualTable(let body) = try parse("""
      CREATE VIRTUAL TABLE documents_body_fts USING fts5(
        body, content='', contentless_delete=1, tokenize='porter unicode61')
      """) else { Issue.record("not createVirtualTable"); return }
    #expect(body.definition.content == .contentless(deleteEnabled: true))

    // IF NOT EXISTS + prefix / detail / columnsize options.
    guard case .createVirtualTable(let sym) = try parse("""
      CREATE VIRTUAL TABLE IF NOT EXISTS sf_symbols_fts USING fts5(
        name, keywords, categories, aliases, prefix='2 3', detail=column, columnsize=0)
      """) else { Issue.record("not createVirtualTable"); return }
    #expect(sym.ifNotExists)
    #expect(sym.definition.columns == ["name", "keywords", "categories", "aliases"])
    #expect(sym.definition.prefix == [2, 3])
    #expect(sym.definition.detail == .column)
    #expect(sym.definition.columnSize == false)
  }

  @Test func rejectsUnknownModuleAndOptionAndEmptyColumns() throws {
    #expect(throws: DBError.self) { _ = try parse("CREATE VIRTUAL TABLE t USING rtree(a, b)") }
    #expect(throws: DBError.self) { _ = try parse("CREATE VIRTUAL TABLE t USING fts5(a, bogus='x')") }
    #expect(throws: DBError.self) { _ = try parse("CREATE VIRTUAL TABLE t USING fts5()") }
  }

  @Test func createPersistsClashesAndDrops() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("fts.adsql")

    do {
      let db = try Database.open(at: path)
      defer { db.close() }
      try db.prepare("""
        CREATE VIRTUAL TABLE documents_fts USING fts5(
          title, abstract, key, tokenize='porter unicode61')
        """).run()

      // The name now occupies the table namespace (both directions clash).
      #expect(throws: DBError.self) {
        try db.prepare("CREATE TABLE documents_fts(x INTEGER)").run()
      }
      // IF NOT EXISTS makes a re-create a no-op.
      try db.prepare("CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(other)").run()

      // White-box: the config round-trips through the catalog encoder.
      let def: FTSDefinition? = try db.writeSync { (txn) throws(DBError) in
        try txn.schema().ftsTables["documents_fts"]
      }
      #expect(def?.columns == ["title", "abstract", "key"])
      #expect(def?.tokenize == ["porter", "unicode61"])
    }

    // Reopen: the FTS record is decoded back from disk.
    do {
      let db = try Database.open(at: path)
      defer { db.close() }
      let def: FTSDefinition? = try db.writeSync { (txn) throws(DBError) in
        try txn.schema().ftsTables["documents_fts"]
      }
      #expect(def?.columns == ["title", "abstract", "key"])
      #expect(def?.content == .selfContained)
      #expect(throws: DBError.self) {
        try db.prepare("CREATE TABLE documents_fts(x INTEGER)").run()
      }

      // DROP TABLE removes the FTS table and frees the name.
      try db.prepare("DROP TABLE documents_fts").run()
      let gone: FTSDefinition? = try db.writeSync { (txn) throws(DBError) in
        try txn.schema().ftsTables["documents_fts"]
      }
      #expect(gone == nil)
      try db.prepare("CREATE TABLE documents_fts(x INTEGER)").run()
      _ = try db.verifyIntegrity(deep: true)

      // DROP IF EXISTS on a missing FTS table no-ops; plain DROP errors.
      try db.prepare("DROP TABLE IF EXISTS missing_fts").run()
      #expect(throws: DBError.self) { try db.prepare("DROP TABLE missing_fts").run() }
    }
  }

  /// Regression: over-long FTS column, tokenizer, and external-content names
  /// surface a catchable `DBError` instead of tripping the catalog encoder's
  /// length `precondition`. The 255-byte boundary still round-trips.
  @Test func rejectsOverLongFTSNamesWithoutTrapping() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("fts-long.adsql"))
    defer { db.close() }

    let tooLong = String(repeating: "a", count: 256)
    #expect(throws: DBError.invalidDefinition("fts5 table c: column name too long")) {
      try db.prepare("CREATE VIRTUAL TABLE c USING fts5(\(tooLong))").run()
    }
    #expect(throws: DBError.invalidDefinition("fts5 table k: tokenizer argument too long")) {
      try db.prepare("CREATE VIRTUAL TABLE k USING fts5(body, tokenize='\(tooLong)')").run()
    }
    #expect(throws: DBError.invalidDefinition("fts5 table x: content table/rowid name too long")) {
      try db.prepare(
        "CREATE VIRTUAL TABLE x USING fts5(body, content='\(tooLong)', content_rowid='id')"
      ).run()
    }

    let atLimit = String(repeating: "b", count: 255)
    try db.prepare("CREATE VIRTUAL TABLE ok USING fts5(\(atLimit))").run()
    let columns: [String]? = try db.writeSync { (txn) throws(DBError) in
      try txn.schema().ftsTables["ok"]?.columns
    }
    #expect(columns == [atLimit])
  }
}
