import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

// NOTE: `catch let error as DBError` (always-true cast) miscompiles in the
// Swift 6.4 SIL ownership verifier; plain propagation and `as?` casts in
// catch bodies avoid it.
private func parse(_ sql: String) throws -> SQLStatementAST {
  try SQLParser.parseOne(sql)
}

private func selectOf(_ sql: String) throws -> SQLSelect {
  guard case .select(let s) = try parse(sql) else {
    throw DBError.sqlSyntax(message: "not a select", offset: 0)
  }
  return s
}

@Suite("SQL parser — statements")
struct SQLParserStatementTests {
  @Test func blobLiterals() throws {
    let s = try selectOf("SELECT x'00FF', X'cafe', x''")
    if case .expr(let e, _, _) = s.columns[0] { #expect(e == .literal(.blob([0x00, 0xFF]))) }
    if case .expr(let e, _, _) = s.columns[1] { #expect(e == .literal(.blob([0xCA, 0xFE]))) }
    if case .expr(let e, _, _) = s.columns[2] { #expect(e == .literal(.blob([]))) }
  }

  @Test func selectCoreShapes() throws {
    let s = try selectOf("""
      SELECT d.id, d.key AS path, COALESCE(r.display_name, d.framework) framework
      FROM documents d
      LEFT JOIN roots r ON r.slug = d.framework
      WHERE d.key = ? AND (d.language IS NULL OR d.language = $lang OR d.language = 'both')
      ORDER BY d.key, length(d.key) DESC
      LIMIT $limit OFFSET 2
      """)
    #expect(s.columns.count == 3)
    if case .expr(_, let alias, _) = s.columns[1] { #expect(alias == "path") }
    if case .expr(_, let alias, let text) = s.columns[2] {
      #expect(alias == "framework")
      #expect(text.hasPrefix("COALESCE"))
    }
    #expect(s.from?.name == "documents" && s.from?.alias == "d")
    #expect(s.joins.count == 1 && s.joins[0].kind == .left)
    #expect(s.orderBy.count == 2)
    #expect(s.orderBy[0].descending == false)
    #expect(s.orderBy[1].descending == true)
    if case .parameter(.named(let name), _) = s.limit {
      #expect(name == "limit")
    } else {
      Issue.record("limit is not a named parameter")
    }
    #expect(s.offset == .literal(.integer(2)))
    #expect(s.whereExpr != nil)
  }

  @Test func searchShapedQuery() throws {
    // The apple-docs FTS-search SELECT minus MATCH (M5): tier CASE + filters.
    let s = try selectOf("""
      SELECT d.id, d.key,
             CASE
               WHEN LOWER(d.title) = LOWER($raw) THEN 0
               WHEN LOWER(d.title) LIKE LOWER($raw) || '%' THEN 1
               WHEN INSTR(LOWER(d.title), LOWER($raw)) > 0 THEN 2
               ELSE 3
             END AS tier
      FROM documents d
      LEFT JOIN roots r ON r.slug = d.framework
      WHERE ($framework IS NULL OR d.framework = $framework)
        AND ($sources_json IS NULL OR d.source_type IN (SELECT value FROM json_each($sources_json)))
        AND ($year IS NULL OR CAST(json_extract(d.source_metadata, '$.year') AS INTEGER) = $year)
        AND ($deprecated_mode = 'include' OR COALESCE(d.is_deprecated, 0) = 0)
      ORDER BY tier, CASE WHEN d.role = 'symbol' THEN 0 ELSE 1 END, length(d.key)
      LIMIT $limit
      """)
    #expect(s.columns.count == 3)
    #expect(s.orderBy.count == 3)
    // The IN json_each shape parsed into the dedicated node.
    func containsJSONEach(_ e: SQLExpr) -> Bool {
      switch e {
      case .inJSONEach: return true
      case .binary(_, let l, let r): return containsJSONEach(l) || containsJSONEach(r)
      case .unary(_, let inner), .collate(let inner, _), .cast(let inner, _):
        return containsJSONEach(inner)
      case .isNull(let inner, _): return containsJSONEach(inner)
      default: return false
      }
    }
    #expect(containsJSONEach(s.whereExpr!))
  }

  @Test func groupByAggregatesUnion() throws {
    let s = try selectOf("""
      SELECT root_slug, COUNT(*) AS total,
             SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending
      FROM crawl_state GROUP BY root_slug, status HAVING COUNT(*) > 1
      UNION ALL
      SELECT alias, 0, 0 FROM framework_synonyms
      UNION
      SELECT canonical, 0, 0 FROM framework_synonyms
      """)
    #expect(s.groupBy.count == 2)
    #expect(s.having != nil)
    #expect(s.compounds.count == 2)
    #expect(s.compounds[0].op == .unionAll)
    #expect(s.compounds[1].op == .union)
  }

  @Test func correlatedScalarSubquery() throws {
    let s = try selectOf(
      "SELECT slug, (SELECT COUNT(*) FROM pages WHERE pages.root_id = roots.id) n FROM roots")
    guard case .expr(.scalarSubquery(let sub), let alias, _) = s.columns[1] else {
      Issue.record("expected scalar subquery")
      return
    }
    #expect(alias == "n")
    #expect(sub.from?.name == "pages")
  }

  @Test func insertVariants() throws {
    guard case .insert(let plain) = try parse(
      "INSERT INTO kv (k, v) VALUES (?, ?), ($a, $b)")
    else { Issue.record("not insert"); return }
    #expect(plain.columns == ["k", "v"])
    #expect(plain.rows.count == 2)
    #expect(plain.conflict == .abort)

    guard case .insert(let orReplace) = try parse(
      "INSERT OR REPLACE INTO document_vectors(document_id, vec) VALUES ($id, $vec)")
    else { Issue.record("not insert"); return }
    #expect(orReplace.conflict == .replace)

    guard case .insert(let replaceInto) = try parse("REPLACE INTO t (a) VALUES (1)")
    else { Issue.record("not insert"); return }
    #expect(replaceInto.conflict == .replace)

    guard case .insert(let ignore) = try parse("INSERT OR IGNORE INTO t (a) VALUES (1)")
    else { Issue.record("not insert"); return }
    #expect(ignore.conflict == .ignore)

    guard case .insert(let upsert) = try parse("""
      INSERT INTO roots (slug, display_name) VALUES ($slug, $name)
      ON CONFLICT(slug) DO UPDATE SET display_name = excluded.display_name,
        page_count = page_count + 1
      RETURNING id
      """)
    else { Issue.record("not insert"); return }
    guard case .doUpdate(let target, let sets) = upsert.conflict else {
      Issue.record("expected DO UPDATE")
      return
    }
    #expect(target == "slug")
    #expect(sets.count == 2)
    if case .column(let table, let name, _) = sets[0].value {
      #expect(table == "excluded" && name == "display_name")
    } else {
      Issue.record("expected excluded.display_name column ref")
    }
    #expect(upsert.returning.count == 1)

    guard case .insert(let doNothing) = try parse(
      "INSERT INTO t (a) VALUES (1) ON CONFLICT(a) DO NOTHING")
    else { Issue.record("not insert"); return }
    #expect(doNothing.conflict == .ignore)
  }

  @Test func updateDelete() throws {
    guard case .update(let u) = try parse("""
      UPDATE pages SET consecutive_404_count = consecutive_404_count + 1, status = $s
      WHERE path = ? RETURNING consecutive_404_count
      """)
    else { Issue.record("not update"); return }
    #expect(u.sets.count == 2)
    #expect(u.whereExpr != nil)
    #expect(u.returning.count == 1)

    guard case .delete(let d) = try parse("DELETE FROM documents WHERE key = ?")
    else { Issue.record("not delete"); return }
    #expect(d.table == "documents")
    #expect(d.returning.isEmpty)
  }

  @Test func createTableFull() throws {
    guard case .createTable(let ct) = try parse("""
      CREATE TABLE IF NOT EXISTS documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL COLLATE NOCASE,
        framework TEXT,
        is_deprecated INTEGER DEFAULT 0,
        score REAL DEFAULT -1.5,
        created_at TEXT DEFAULT (datetime('now')),
        root_id INTEGER REFERENCES roots(id) ON DELETE CASCADE,
        CHECK (id > 0),
        UNIQUE (framework, key),
        FOREIGN KEY (root_id) REFERENCES roots(id) ON DELETE RESTRICT
      ) STRICT
      """)
    else { Issue.record("not createTable"); return }
    let def = ct.definition
    #expect(ct.ifNotExists)
    #expect(def.primaryKey == .rowidAlias(column: "id", autoincrement: true))
    #expect(def.columns.count == 8)
    #expect(def.columns[1].notNull)
    #expect(def.columns[2].collation == .nocase)
    #expect(def.columns[4].defaultValue == .value(.integer(0)))
    #expect(def.columns[5].defaultValue == .value(.real(-1.5)))
    #expect(def.columns[6].defaultValue == .datetimeNow)
    #expect(def.foreignKeys.count == 2)
    #expect(def.foreignKeys[0].onDelete == .cascade)
    #expect(def.foreignKeys[1].onDelete == .restrict)
    // Implied unique indexes: column UNIQUE + table UNIQUE.
    #expect(ct.impliedIndexes.map(\.columns) == [["key"], ["framework", "key"]])
    let allUnique = ct.impliedIndexes.allSatisfy(\.unique)
    #expect(allUnique)
    #expect(ct.impliedIndexes[0].name == "sqlite_autoindex_documents_1")
  }

  @Test func tableLevelPrimaryKey() throws {
    // Multi-column PK → implied unique index + NOT NULL.
    guard case .createTable(let ct) = try parse(
      "CREATE TABLE sf (scope TEXT, name TEXT, PRIMARY KEY (scope, name))")
    else { Issue.record("not createTable"); return }
    #expect(ct.definition.primaryKey == .implicitRowid)
    #expect(ct.impliedIndexes.first?.columns == ["scope", "name"])
    let allNotNull = ct.definition.columns.allSatisfy(\.notNull)
    #expect(allNotNull)

    // Single INTEGER table-level PK → rowid alias.
    guard case .createTable(let ct2) = try parse(
      "CREATE TABLE t (id INTEGER, PRIMARY KEY (id))")
    else { Issue.record("not createTable"); return }
    #expect(ct2.definition.primaryKey == .rowidAlias(column: "id", autoincrement: false))
  }

  @Test func indexAndDropAndTxn() throws {
    guard case .createIndex(let ci) = try parse(
      "CREATE UNIQUE INDEX IF NOT EXISTS u_docs_key ON documents (key)")
    else { Issue.record("not createIndex"); return }
    #expect(ci.definition.unique && ci.ifNotExists)

    guard case .dropTable(let name, let ifExists) = try parse("DROP TABLE IF EXISTS old")
    else { Issue.record("not dropTable"); return }
    #expect(name == "old" && ifExists)

    let begin = try parse("BEGIN IMMEDIATE")
    #expect(begin == .begin)
    let commit = try parse("COMMIT")
    #expect(commit == .commit)
    let rollback = try parse("ROLLBACK TRANSACTION")
    #expect(rollback == .rollback)
  }

  @Test func keywordsAsIdentifiers() throws {
    // "key" and "match" are common column names in apple-docs.
    let s = try selectOf("SELECT key FROM documents WHERE key = 'x'")
    if case .expr(.column(_, let name, _), _, _) = s.columns[0] {
      #expect(name == "key")
    } else {
      Issue.record("key not parsed as column")
    }
  }

  @Test func scriptSplitting() throws {
    let script = try SQLParser.parseScript("""
      CREATE TABLE t (a INTEGER);
      INSERT INTO t (a) VALUES (1);
      -- comment between statements
      SELECT * FROM t;
      """)
    #expect(script.count == 3)
  }
}

@Suite("SQL parser — errors")
struct SQLParserErrorTests {
  static let unsupported: [(String, String)] = [
    ("WITH x AS (SELECT 1) SELECT * FROM x", "WITH"),
    ("SELECT * FROM t WHERE a BETWEEN 1 AND 2", "BETWEEN"),
    ("SELECT * FROM docs WHERE docs MATCH 'q'", "MATCH"),
    ("SELECT COUNT(DISTINCT a) FROM t", "DISTINCT"),
    ("SELECT AVG(a) FROM t", "AVG"),
    ("SELECT MAX(a) FROM t", "MAX"),
    ("SELECT bm25(fts) FROM fts", "bm25"),
    ("SELECT a, ROW_NUMBER() OVER (ORDER BY a) FROM t", "window"),
    ("SELECT * FROM (SELECT 1)", "FROM"),
    ("SELECT * FROM a, b", "comma join"),
    ("SELECT * FROM a RIGHT JOIN b ON a.x = b.x", "RIGHT"),
    ("SELECT * FROM a JOIN b USING (x)", "USING"),
    ("SELECT 1 EXCEPT SELECT 2", "EXCEPT"),
    ("SELECT 1 LIMIT 1, 2", "LIMIT offset"),
    ("CREATE VIRTUAL TABLE f USING fts5(a)", "VIRTUAL"),
    ("CREATE TABLE t (a INTEGER) WITHOUT ROWID", "WITHOUT ROWID"),
    ("INSERT INTO t SELECT * FROM s", "SELECT"),
    ("SELECT * FROM t WHERE a IN (SELECT b FROM s)", "json_each"),
    ("SELECT * FROM t WHERE EXISTS (SELECT 1)", "EXISTS"),
    ("SELECT ?1", "?NNN"),
    ("SELECT x'012'", "odd-length blob"),
    ("SELECT x'0g'", "non-hex blob"),
  ]

  @Test(arguments: unsupported.indices)
  func reservedConstructs(_ index: Int) {
    let (sql, _) = Self.unsupported[index]
    do {
      _ = try SQLParser.parseOne(sql)
      Issue.record("\(sql) parsed but must be rejected")
    } catch {
      switch error {
      case .sqlUnsupported, .sqlSyntax: break
      default: Issue.record("\(sql) threw unexpected \(error)")
      }
    }
  }

  @Test func syntaxErrorsCarryOffsets() {
    do {
      _ = try SQLParser.parseOne("SELECT FROM t")
      Issue.record("must fail")
    } catch {
      guard case DBError.sqlSyntax(_, let offset) = error else {
        Issue.record("wrong error \(error)")
        return
      }
      #expect(offset == 7) // FROM begins the failure
    }
  }

  @Test func fuzzTruncateAndSplice() {
    let corpus = SQLParserStatementTests().corpusForFuzz
      + SQLParserErrorTests.unsupported.map(\.0)
    var rng = SplitMix64(seed: 0xF00D)
    var attempts = 0
    for sql in corpus {
      let bytes = Array(sql.utf8)
      for _ in 0..<40 {
        attempts += 1
        var mutated = bytes
        switch rng.next() % 3 {
        case 0: // truncate
          mutated = Array(mutated.prefix(Int(rng.next() % UInt64(max(1, mutated.count)))))
        case 1: // splice random bytes
          let at = Int(rng.next() % UInt64(max(1, mutated.count)))
          mutated.insert(contentsOf: RandomValues.bytes(&rng, maxLength: 6), at: at)
        default: // swap a chunk from another corpus entry
          let other = Array(corpus[Int(rng.next() % UInt64(corpus.count))].utf8)
          let cut = Int(rng.next() % UInt64(max(1, mutated.count)))
          mutated = Array(mutated.prefix(cut)) + other.suffix(Int(rng.next() % 24))
        }
        let text = String(decoding: mutated, as: UTF8.self)
        // Must never crash; outcome is parse-or-typed-error.
        _ = try? SQLParser.parseScript(text)
      }
    }
    #expect(attempts > 1000)
  }
}

extension SQLParserStatementTests {
  var corpusForFuzz: [String] {
    [
      "SELECT d.id, d.key FROM documents d LEFT JOIN roots r ON r.slug = d.framework WHERE d.key = ? ORDER BY d.key LIMIT 10",
      "INSERT INTO roots (slug, display_name) VALUES ($slug, $name) ON CONFLICT(slug) DO UPDATE SET display_name = excluded.display_name RETURNING id",
      "CREATE TABLE documents (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL UNIQUE, title TEXT COLLATE NOCASE)",
      "UPDATE pages SET n = n + 1 WHERE path = ? RETURNING n",
      "DELETE FROM documents WHERE key = $key",
      "SELECT root_slug, COUNT(*), SUM(CASE WHEN s = 'p' THEN 1 ELSE 0 END) FROM cs GROUP BY root_slug HAVING COUNT(*) > 1",
      "SELECT alias FROM fs WHERE canonical = ? UNION SELECT canonical FROM fs WHERE alias = ?",
      "SELECT CAST(json_extract(m, '$.year') AS INTEGER) FROM d WHERE a IN (SELECT value FROM json_each($j))",
    ]
  }
}
