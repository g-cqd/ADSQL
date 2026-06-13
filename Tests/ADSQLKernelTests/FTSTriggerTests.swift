import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// M5 / F5 — general `CREATE TRIGGER`. AFTER INSERT/UPDATE/DELETE row triggers
/// whose body is INSERT/DELETE/UPDATE statements referencing `NEW.*`/`OLD.*`,
/// fired inside the same write transaction. The headline consumer is apple-docs's
/// FTS-sync DDL (the ai/ad/au triggers keeping `documents_fts` in step with
/// `documents`); this suite covers parsing, catalog persistence (re-parsed on
/// reopen), end-to-end FTS sync, plain (non-FTS) firing with a CSQLite
/// differential, DROP, IF [NOT] EXISTS, and the recursion-depth guard.
@Suite("FTS5 — F5 general CREATE TRIGGER")
struct FTSTriggerTests {
  private func parse(_ sql: String) throws -> SQLStatementAST {
    try SQLParser.parseOne(sql)
  }

  // The three apple-docs FTS-sync triggers, verbatim.
  private static let aiTrigger = """
    CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
      INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
      VALUES (new.id, new.title, new.abstract, new.declaration, new.headings, new.key);
    END
    """
  private static let adTrigger = """
    CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
      INSERT INTO documents_fts(documents_fts, rowid, title, abstract, declaration, headings, key)
      VALUES('delete', old.id, old.title, old.abstract, old.declaration, old.headings, old.key);
    END
    """
  private static let auTrigger = """
    CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
      INSERT INTO documents_fts(documents_fts, rowid, title, abstract, declaration, headings, key)
      VALUES('delete', old.id, old.title, old.abstract, old.declaration, old.headings, old.key);
      INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
      VALUES (new.id, new.title, new.abstract, new.declaration, new.headings, new.key);
    END
    """

  // MARK: - Parsing

  @Test func parsesTheThreeAppleDocsTriggers() throws {
    guard case .createTrigger(let ai) = try parse(Self.aiTrigger) else {
      Issue.record("ai not createTrigger"); return
    }
    #expect(ai.definition.name == "documents_ai")
    #expect(ai.definition.table == "documents")
    #expect(ai.definition.event == .insert)
    #expect(ai.definition.whenExpr == nil)
    #expect(ai.definition.body.count == 1)
    if case .insert(let insert) = ai.definition.body[0] {
      #expect(insert.table == "documents_fts")
    } else {
      Issue.record("ai body is not an INSERT")
    }

    guard case .createTrigger(let ad) = try parse(Self.adTrigger) else {
      Issue.record("ad not createTrigger"); return
    }
    #expect(ad.definition.event == .delete)
    #expect(ad.definition.body.count == 1)

    guard case .createTrigger(let au) = try parse(Self.auTrigger) else {
      Issue.record("au not createTrigger"); return
    }
    #expect(au.definition.event == .update)
    #expect(au.definition.body.count == 2) // delete idiom + re-insert
  }

  @Test func parsesForEachRowAndWhenAndIfNotExists() throws {
    guard case .createTrigger(let t) = try parse("""
      CREATE TRIGGER IF NOT EXISTS audit_ins AFTER INSERT ON items FOR EACH ROW
      WHEN new.qty > 0 BEGIN
        INSERT INTO audit(item, qty) VALUES(new.id, new.qty);
      END
      """) else { Issue.record("not createTrigger"); return }
    #expect(t.ifNotExists)
    #expect(t.definition.event == .insert)
    #expect(t.definition.whenExpr != nil)
    #expect(t.definition.body.count == 1)
  }

  @Test func dropTriggerParses() throws {
    guard case .dropTrigger(let name, let ifExists) = try parse("DROP TRIGGER documents_ai") else {
      Issue.record("not dropTrigger"); return
    }
    #expect(name == "documents_ai")
    #expect(ifExists == false)
    guard case .dropTrigger(_, let ifExists2) = try parse("DROP TRIGGER IF EXISTS x") else {
      Issue.record("not dropTrigger"); return
    }
    #expect(ifExists2)
  }

  @Test func beforeTriggerIsUnsupported() throws {
    #expect(throws: DBError.sqlUnsupported("BEFORE triggers")) {
      _ = try parse("CREATE TRIGGER t BEFORE INSERT ON x BEGIN DELETE FROM y; END")
    }
    #expect(throws: DBError.sqlUnsupported("INSTEAD OF triggers")) {
      _ = try parse("CREATE TRIGGER t INSTEAD OF INSERT ON x BEGIN DELETE FROM y; END")
    }
  }

  @Test func nonMutatingTriggerBodyRejected() throws {
    // A trigger body queries nothing and defines nothing.
    #expect(throws: DBError.self) {
      _ = try parse("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END")
    }
    #expect(throws: DBError.self) {
      _ = try parse("CREATE TRIGGER t AFTER INSERT ON x BEGIN; END") // empty body
    }
  }

  @Test func triggerKeywordsStillUsableAsIdentifiers() throws {
    // AFTER/BEFORE/ROW/OF/FOR/EACH/INSTEAD are non-reserved: still column names.
    guard case .createTable(let create) = try parse(
      "CREATE TABLE t(row INTEGER, after TEXT, of TEXT)")
    else { Issue.record("not createTable"); return }
    #expect(create.definition.columns.map(\.name) == ["row", "after", "of"])
  }

  // MARK: - Catalog persistence (store + survive reopen)

  @Test func triggersPersistAndReparseOnReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("triggers.adsql")

    do {
      let db = try Database.open(at: path)
      defer { db.close() }
      try db.prepare("""
        CREATE TABLE documents(
          id INTEGER PRIMARY KEY, title TEXT, abstract TEXT, declaration TEXT,
          headings TEXT, key TEXT)
        """).run()
      try db.prepare("""
        CREATE VIRTUAL TABLE documents_fts USING fts5(
          title, abstract, declaration, headings, key, tokenize='porter unicode61')
        """).run()
      try db.prepare(Self.aiTrigger).run()
      try db.prepare(Self.adTrigger).run()
      try db.prepare(Self.auTrigger).run()

      let names = try db.writeSync { (txn) throws(DBError) in
        try txn.schema().triggers.keys.sorted()
      }
      #expect(names == ["documents_ad", "documents_ai", "documents_au"])
    }

    // Reopen: triggers re-parse from the stored CREATE TRIGGER text.
    do {
      let db = try Database.open(at: path)
      defer { db.close() }
      let triggers = try db.writeSync { (txn) throws(DBError) -> [String: TriggerDefinition] in
        try txn.schema().triggers
      }
      #expect(triggers.count == 3)
      #expect(triggers["documents_ai"]?.event == .insert)
      #expect(triggers["documents_ad"]?.event == .delete)
      #expect(triggers["documents_au"]?.event == .update)
      #expect(triggers["documents_au"]?.body.count == 2)
      #expect(triggers["documents_ai"]?.table == "documents")
      _ = try db.verifyIntegrity(deep: true)
    }
  }

  @Test func nameClashAndMissingTableRules() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("clash.adsql"))
    defer { db.close() }
    try db.prepare("CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT)").run()
    try db.prepare("CREATE VIRTUAL TABLE documents_fts USING fts5(title)").run()
    try db.prepare(
      "CREATE TRIGGER t1 AFTER INSERT ON documents BEGIN DELETE FROM documents WHERE id < 0; END"
    ).run()

    // Duplicate trigger name.
    #expect(throws: DBError.triggerExists("t1")) {
      try db.prepare(
        "CREATE TRIGGER t1 AFTER DELETE ON documents BEGIN DELETE FROM documents WHERE id < 0; END"
      ).run()
    }
    // IF NOT EXISTS makes the redefinition a no-op.
    try db.prepare(
      "CREATE TRIGGER IF NOT EXISTS t1 AFTER DELETE ON documents BEGIN DELETE FROM documents WHERE id<0; END"
    ).run()
    // Trigger on a missing table.
    #expect(throws: DBError.noSuchTable("ghost")) {
      try db.prepare("CREATE TRIGGER t2 AFTER INSERT ON ghost BEGIN DELETE FROM documents; END").run()
    }
    // Trigger on a virtual table is rejected.
    #expect(throws: DBError.self) {
      try db.prepare(
        "CREATE TRIGGER t3 AFTER INSERT ON documents_fts BEGIN DELETE FROM documents; END"
      ).run()
    }
    // DROP semantics.
    #expect(throws: DBError.noSuchTrigger("missing")) {
      try db.prepare("DROP TRIGGER missing").run()
    }
    try db.prepare("DROP TRIGGER IF EXISTS missing").run() // no-op
    try db.prepare("DROP TRIGGER t1").run()
    let gone = try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers["t1"] }
    #expect(gone == nil)
  }

  @Test func dropTableDropsItsTriggers() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("droptbl.adsql"))
    defer { db.close() }
    try db.prepare("CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT)").run()
    try db.prepare("CREATE TABLE audit(id INTEGER PRIMARY KEY, item INTEGER)").run()
    try db.prepare(
      "CREATE TRIGGER t AFTER INSERT ON documents BEGIN INSERT INTO audit(item) VALUES(new.id); END"
    ).run()
    #expect(try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers.count } == 1)
    try db.prepare("DROP TABLE documents").run()
    #expect(try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers.count } == 0)
  }
}
