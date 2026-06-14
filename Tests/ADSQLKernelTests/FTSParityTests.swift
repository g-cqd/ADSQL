import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// M5 / F6a — the FTS *correctness gate* for closing M5. Proves the FOUR
/// apple-docs FTS table shapes work end-to-end in ADSQL and match real SQLite
/// FTS5 on a realistic synthetic corpus (`AppleDocsCorpus`, ~2k docs, seeded so
/// it is byte-identical across runs/machines). For each shape we build the SAME
/// schema + corpus into ADSQL and a `SQLiteMirror`, then assert:
///
///   1. MATCH result-set (rowid SET) equality across a battery of operators
///      (single term, AND, OR, NOT, prefix `term*`, phrase `"a b"`,
///      column-filtered `col:term`) — only the operators each shape supports.
///   2. Ranked top-k ORDER equality (`ORDER BY bm25(tbl, weights) LIMIT k`),
///      mirroring `FTSRankTests.rankedOrderEqualsSQLiteFTS5`.
///
/// The whole differential is guarded by `sqliteHasFTS5()`; when the linked
/// sqlite3 lacks FTS5 we still assert non-differential invariants (anchor terms
/// match a non-empty set, ranked scores are negative and monotonic) so the test
/// is never a silent no-op.
///
/// Shapes & how each is driven (the apple-docs pattern):
///   - `documents_fts`     self-contained, porter; driven through base-table DML
///     via the ai/ad/au sync triggers (so the trigger path is exercised too).
///   - `documents_trigram` external content over `documents`, trigram; populated
///     by INSERTing (rowid, title) read from `documents` (apple-docs idiom).
///   - `documents_body_fts`contentless, porter; populated by INSERT (rowid, body)
///     and deleted via the `'delete'` command idiom.
///   - `sf_symbols_fts`    self-contained, porter, prefix='2 3', detail=column,
///     columnsize=0; populated by direct multi-column INSERT.
///
/// Option-gap findings (see the per-shape tests + the F6a report):
///   - `columnsize=0` is correctness-equivalent today: SQLite FTS5 keeps the
///     per-doc *total* token count regardless, and bm25 length-norm uses that
///     total (which ADSQL computes by summing field lengths) — verified to give
///     bit-identical bm25 vs `columnsize=1`. Only the per-column storage saving
///     is absent (a perf/storage follow-up, not a correctness gap).
///   - `prefix='2 3'` is parse-only: query-time `term*` matching is served by a
///     term-dictionary scan, returning the same rows; the index-time prefix
///     index is a perf optimization, deferred (flagged as follow-up).
///   - `detail=column` (sf_symbols): SQLite *rejects* phrase queries on it; so we
///     issue none for that shape (apple-docs doesn't either).
@Suite("FTS5 — F6a apple-docs shapes ⟷ SQLite FTS5 parity")
struct FTSParityTests {
    // Deterministic, and dense enough that single terms hit a large set and bm25
    // ordering is non-trivial, while staying fast in CI (single-list FTS write
    // amplification — the F6d perf target — makes large builds slow). The bench
    // (F6b) scales the same generator to ≥100k.
    static let docCount = 500
    static let seed: UInt64 = 0xF6A_C0FFEE

    static let corpus = AppleDocsCorpus.generate(count: docCount, seed: seed)

    /// True when the linked sqlite3 has FTS5 compiled in. When false the
    /// differential assertions are skipped and the non-differential invariants
    /// below remain the correctness gate.
    private static func sqliteHasFTS5() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)", nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Small typed helpers

    /// rowids for a MATCH query against an ADSQL FTS table, ascending.
    private func adsqlRowids(_ db: Database, _ table: String, _ query: String) throws -> [Int64] {
        try db.prepare("SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rowid")
            .all(.text(query)).map { row in
                guard case .integer(let id) = row[0] else { return Int64(-1) }
                return id
            }
    }

    /// rowids for a MATCH query against the SQLite mirror table, ascending.
    private func sqliteRowids(_ m: SQLiteMirror, _ table: String, _ query: String) throws -> [Int64] {
        try m.query("SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rowid", [.text(query)])
            .map { row in
                guard case .integer(let id) = row[0] else { return Int64(-1) }
                return id
            }
    }

    /// Ranked top-k rowids for ADSQL: `ORDER BY <orderExpr>, rowid LIMIT k`, best
    /// first. The explicit `, rowid` makes equal-score ties deterministic (rowid
    /// ascending) identically to SQLite below, so parity holds regardless of how
    /// either engine breaks fully-equal `ORDER BY ... LIMIT` keys internally.
    private func adsqlRanked(
        _ db: Database, _ table: String, _ orderExpr: String, _ query: String, limit: Int
    ) throws -> [Int64] {
        try db.prepare(
            "SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY \(orderExpr), rowid LIMIT \(limit)"
        ).all(.text(query)).map { row in
            guard case .integer(let id) = row[0] else { return Int64(-1) }
            return id
        }
    }

    /// Ranked top-k rowids for the SQLite mirror (same `, rowid` tiebreak as ADSQL).
    private func sqliteRanked(
        _ m: SQLiteMirror, _ table: String, _ orderExpr: String, _ query: String, limit: Int
    ) throws -> [Int64] {
        try m.query(
            "SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY \(orderExpr), rowid LIMIT \(limit)",
            [.text(query)]
        ).map { row in
            guard case .integer(let id) = row[0] else { return Int64(-1) }
            return id
        }
    }

    /// Ranked bm25 scores for ADSQL in ascending (best-first) order — for the
    /// non-differential invariant when SQLite FTS5 is unavailable.
    private func adsqlScores(
        _ db: Database, _ table: String, _ orderExpr: String, _ query: String
    ) throws -> [Double] {
        try db.prepare(
            "SELECT \(orderExpr) FROM \(table) WHERE \(table) MATCH ? ORDER BY \(orderExpr)"
        ).all(.text(query)).map { row in
            guard case .real(let s) = row[0] else { return .nan }
            return s
        }
    }

    // MARK: - Shape 1: documents_fts (self-contained, porter, trigger-driven)

    /// Base `documents` + `documents_fts` + the three apple-docs sync triggers.
    /// The FTS index is populated *entirely through base-table INSERTs* so the
    /// ai/ad/au trigger path is what fills it (the apple-docs production shape).
    private static let documentsSchema = """
        CREATE TABLE documents(
          id INTEGER PRIMARY KEY, title TEXT, abstract TEXT, declaration TEXT,
          headings TEXT, key TEXT)
        """
    private static let documentsFTS = """
        CREATE VIRTUAL TABLE documents_fts USING fts5(
          title, abstract, declaration, headings, key, tokenize='porter unicode61')
        """
    // Verbatim apple-docs ai/ad/au triggers (identical text drives both engines).
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

    private func buildDocumentsFTS(_ db: Database) throws {
        try db.prepare(Self.documentsSchema).run()
        try db.prepare(Self.documentsFTS).run()
        try db.prepare(Self.aiTrigger).run()
        try db.prepare(Self.adTrigger).run()
        try db.prepare(Self.auTrigger).run()
        let insert = try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(?, ?, ?, ?, ?, ?)
            """)
        for d in Self.corpus {
            try insert.run(
                .integer(d.id), .text(d.title), .text(d.abstract), .text(d.declaration),
                .text(d.headings), .text(d.key))
        }
    }

    private func mirrorDocumentsFTS() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(Self.documentsSchema)
        try m.exec(Self.documentsFTS)
        try m.exec(Self.aiTrigger)
        try m.exec(Self.adTrigger)
        try m.exec(Self.auTrigger)
        for d in Self.corpus {
            try m.insertRow(
                "documents", ["id", "title", "abstract", "declaration", "headings", "key"],
                [
                    .integer(d.id), .text(d.title), .text(d.abstract), .text(d.declaration),
                    .text(d.headings), .text(d.key),
                ])
        }
        return m
    }

    /// The MATCH battery for the porter `documents_fts` shape: every supported
    /// operator. Terms are drawn from the generator vocabulary so each hits a
    /// meaningful, varied subset.
    private static let documentsQueries = [
        // single term (anchor + prose + stemmed)
        "swiftui", "metal", "view", "rendering", "concurrent",
        // AND / OR / NOT
        "view AND model", "swiftui OR uikit", "view NOT swiftui",
        "structured AND view", "metal OR vision",
        // prefix
        "render*", "config*", "swif*", "navig*",
        // phrase (full detail ⇒ positions ⇒ adjacency)
        "\"renders the view\"", "\"final class\"", "\"conforms to\"",
        // column-filtered
        "title:swiftui", "abstract:view", "declaration:struct", "key:metal",
        "title:swif*", "abstract:render*",
        // compound
        "view AND (model OR context)", "title:swiftui NOT abstract:lazy",
    ]

    @Test func documentsFTSMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("docs.adsql"))
        defer { db.close() }
        try buildDocumentsFTS(db)

        // Non-differential invariant (always runs): anchor terms hit a non-empty,
        // bounded set; ranked scores are negative and monotonic best-first.
        let anchor = try adsqlRowids(db, "documents_fts", "swiftui")
        #expect(!anchor.isEmpty && anchor.count <= Self.docCount)
        let scores = try adsqlScores(db, "documents_fts", "bm25(documents_fts, 10,5,3,2,1)", "view")
        #expect(scores == scores.sorted(), "ranked scores must be ascending (best first)")
        #expect(scores.allSatisfy { $0 < 0 }, "bm25 scores are negative by FTS5 convention")

        guard Self.sqliteHasFTS5() else { return }  // documented skip
        let m = try mirrorDocumentsFTS()

        // MATCH result-set (rowid SET) equality.
        for q in Self.documentsQueries {
            let ours = try adsqlRowids(db, "documents_fts", q)
            let theirs = try sqliteRowids(m, "documents_fts", q)
            #expect(ours == theirs, "documents_fts MATCH '\(q)': adsql \(ours.count) vs sqlite \(theirs.count)")
        }

        // Ranked top-k ORDER equality — apple-docs weights 10,5,3,2,1.
        let weights = "10.0, 5.0, 3.0, 2.0, 1.0"
        let rankCases: [(String, Int)] = [
            ("swiftui", 20), ("view", 50), ("metal OR vision", 30),
            ("structured AND view", 25), ("render*", 40), ("config*", 20),
        ]
        for (q, k) in rankCases {
            let ours = try adsqlRanked(db, "documents_fts", "bm25(documents_fts, \(weights))", q, limit: k)
            let theirs = try sqliteRanked(m, "documents_fts", "bm25(documents_fts, \(weights))", q, limit: k)
            #expect(ours == theirs, "documents_fts top-\(k) bm25 '\(q)': adsql \(ours) vs sqlite \(theirs)")
            // `rank` == bm25 with all weights == 1 (sanity vs the weighted form differing).
            let byRank = try adsqlRanked(db, "documents_fts", "rank", q, limit: k)
            let byRankSQLite = try sqliteRanked(m, "documents_fts", "rank", q, limit: k)
            #expect(byRank == byRankSQLite, "documents_fts top-\(k) rank '\(q)'")
        }
    }

    // MARK: - Shape 2: documents_trigram (external content, trigram)

    /// External content over `documents`: the FTS table indexes `title` and reads
    /// its rowid from `documents.id`. apple-docs populates it by INSERTing
    /// (rowid, title) selected from `documents`; we do the same into both engines.
    /// Trigram ⇒ substring matching, so the query battery uses substrings (≥3
    /// chars), no boolean phrase / stemming.
    private static let documentsTrigram = """
        CREATE VIRTUAL TABLE documents_trigram USING fts5(
          title, content='documents', content_rowid='id', tokenize='trigram case_sensitive 0')
        """

    private func buildTrigram(_ db: Database) throws {
        // Base table (so the external-content DDL resolves) + the FTS table.
        try db.prepare(Self.documentsSchema).run()
        try db.prepare(Self.documentsTrigram).run()
        let baseInsert = try db.prepare("INSERT INTO documents(id, title) VALUES(?, ?)")
        let ftsInsert = try db.prepare("INSERT INTO documents_trigram(rowid, title) VALUES(?, ?)")
        for d in Self.corpus {
            try baseInsert.run(.integer(d.id), .text(d.title))
            try ftsInsert.run(.integer(d.id), .text(d.title))
        }
    }

    private func mirrorTrigram() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(Self.documentsSchema)
        try m.exec(Self.documentsTrigram)
        for d in Self.corpus {
            try m.insertRow("documents", ["id", "title"], [.integer(d.id), .text(d.title)])
            try m.insertRow("documents_trigram", ["rowid", "title"], [.integer(d.id), .text(d.title)])
        }
        return m
    }

    /// Substring queries (≥3 chars) — trigram's domain. Mixes case to exercise
    /// `case_sensitive 0`, and substrings that span type/framework boundaries.
    private static let trigramQueries = [
        "wif", "Swift", "view", "Kit", " async", "roll", "ller", "Combine",
        "data", "able", "ation", "Render", "grid", "stack",
    ]

    @Test func documentsTrigramMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("trigram.adsql"))
        defer { db.close() }
        try buildTrigram(db)

        // Non-differential invariant: a substring present in the vocabulary matches.
        let anchor = try adsqlRowids(db, "documents_trigram", "Swift")
        #expect(!anchor.isEmpty)
        let scores = try adsqlScores(db, "documents_trigram", "rank", "view")
        #expect(scores == scores.sorted())
        #expect(scores.allSatisfy { $0 < 0 })

        guard Self.sqliteHasFTS5() else { return }
        let m = try mirrorTrigram()

        for q in Self.trigramQueries {
            let ours = try adsqlRowids(db, "documents_trigram", q)
            let theirs = try sqliteRowids(m, "documents_trigram", q)
            #expect(ours == theirs, "documents_trigram MATCH '\(q)': adsql \(ours.count) vs sqlite \(theirs.count)")
        }

        // Ranked top-k (natural single-column weight) order equality.
        let rankCases: [(String, Int)] = [("Swift", 30), ("view", 40), ("Kit", 20), ("ation", 25)]
        for (q, k) in rankCases {
            let ours = try adsqlRanked(db, "documents_trigram", "rank", q, limit: k)
            let theirs = try sqliteRanked(m, "documents_trigram", "rank", q, limit: k)
            #expect(ours == theirs, "documents_trigram top-\(k) '\(q)': adsql \(ours) vs sqlite \(theirs)")
        }
    }

    // MARK: - Shape 3: documents_body_fts (contentless, porter)

    /// Contentless (`content=''`, `contentless_delete=1`): the index stores no
    /// columns, only the inverted index. Populated by direct (rowid, body) INSERT;
    /// the `'delete'` command idiom removes rows. Same data into both engines.
    private static let documentsBodyFTS = """
        CREATE VIRTUAL TABLE documents_body_fts USING fts5(
          body, content='', contentless_delete=1, tokenize='porter unicode61')
        """

    private func buildBodyFTS(_ db: Database) throws {
        try db.prepare(Self.documentsBodyFTS).run()
        let insert = try db.prepare("INSERT INTO documents_body_fts(rowid, body) VALUES(?, ?)")
        for d in Self.corpus { try insert.run(.integer(d.id), .text(d.body)) }
    }

    private func mirrorBodyFTS() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(Self.documentsBodyFTS)
        for d in Self.corpus {
            try m.insertRow("documents_body_fts", ["rowid", "body"], [.integer(d.id), .text(d.body)])
        }
        return m
    }

    private static let bodyQueries = [
        "view", "buffer", "concurrent", "structured", "render*",
        "view AND buffer", "buffer OR texture", "view NOT lazy",
        "\"observes the value\"", "\"structured view\"",
        "swiftui", "metal", "observable AND model",
    ]

    @Test func documentsBodyFTSMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("body.adsql"))
        defer { db.close() }
        try buildBodyFTS(db)

        let anchor = try adsqlRowids(db, "documents_body_fts", "view")
        #expect(!anchor.isEmpty)
        let scores = try adsqlScores(db, "documents_body_fts", "rank", "buffer")
        #expect(scores == scores.sorted())
        #expect(scores.allSatisfy { $0 < 0 })

        guard Self.sqliteHasFTS5() else { return }
        let m = try mirrorBodyFTS()

        for q in Self.bodyQueries {
            let ours = try adsqlRowids(db, "documents_body_fts", q)
            let theirs = try sqliteRowids(m, "documents_body_fts", q)
            #expect(ours == theirs, "documents_body_fts MATCH '\(q)': adsql \(ours.count) vs sqlite \(theirs.count)")
        }

        let rankCases: [(String, Int)] = [("view", 50), ("buffer", 30), ("render*", 40), ("concurrent", 25)]
        for (q, k) in rankCases {
            let ours = try adsqlRanked(db, "documents_body_fts", "rank", q, limit: k)
            let theirs = try sqliteRanked(m, "documents_body_fts", "rank", q, limit: k)
            #expect(ours == theirs, "documents_body_fts top-\(k) '\(q)': adsql \(ours) vs sqlite \(theirs)")
        }

        // contentless_delete=1 enables an ordinary `DELETE FROM … WHERE rowid = ?`
        // (this is the whole point of the option — a plain contentless table cannot
        // delete; `contentless_delete=1` can). NOTE: SQLite *rejects* the `'delete'`
        // command idiom on a contentless_delete=1 table ("'delete' may not be used
        // with a contentless_delete=1 table"), so the row deletion must go through
        // DELETE. Both engines delete the same rowid; the result sets stay equal.
        let victim = anchor.first ?? 1
        try db.prepare("DELETE FROM documents_body_fts WHERE rowid = ?").run(.integer(victim))
        _ = try m.query("DELETE FROM documents_body_fts WHERE rowid = ?", [.integer(victim)])
        let oursAfter = try adsqlRowids(db, "documents_body_fts", "view")
        let theirsAfter = try sqliteRowids(m, "documents_body_fts", "view")
        #expect(oursAfter == theirsAfter, "post-delete parity")
        #expect(!oursAfter.contains(victim), "deleted rowid must be gone")
    }

    // MARK: - Shape 4: sf_symbols_fts (self-contained, prefix index, detail=column, columnsize=0)

    /// Prefix index + `detail=column` (no positions ⇒ no phrase queries) +
    /// `columnsize=0`. Direct multi-column INSERT. The query battery uses terms,
    /// booleans, prefixes, and column filters — NOT phrases (SQLite rejects phrase
    /// queries on detail!=full).
    private static let sfSymbolsFTS = """
        CREATE VIRTUAL TABLE sf_symbols_fts USING fts5(
          name, keywords, categories, aliases, prefix='2 3', detail=column, columnsize=0)
        """

    private func buildSFSymbols(_ db: Database) throws {
        try db.prepare(Self.sfSymbolsFTS).run()
        let insert = try db.prepare(
            "INSERT INTO sf_symbols_fts(rowid, name, keywords, categories, aliases) VALUES(?, ?, ?, ?, ?)")
        for d in Self.corpus {
            try insert.run(
                .integer(d.id), .text(d.name), .text(d.keywords), .text(d.categories), .text(d.aliases))
        }
    }

    private func mirrorSFSymbols() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(Self.sfSymbolsFTS)
        for d in Self.corpus {
            try m.insertRow(
                "sf_symbols_fts", ["rowid", "name", "keywords", "categories", "aliases"],
                [.integer(d.id), .text(d.name), .text(d.keywords), .text(d.categories), .text(d.aliases)])
        }
        return m
    }

    /// No phrases (detail=column). Default tokenizer (unicode61, no porter) ⇒ no
    /// stemming; the dotted symbol names tokenize on the separators.
    private static let sfSymbolsQueries = [
        "share", "favorite", "search", "circle", "fill",
        "share AND export", "favorite OR like", "search NOT delete",
        "shar*", "fav*", "circ*", "sett*",
        "keywords:share", "categories:weather", "aliases:heart", "name:circle",
        "keywords:shar*", "aliases:fav*",
        "share AND (export OR upload)",
    ]

    @Test func sfSymbolsFTSMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("sf.adsql"))
        defer { db.close() }
        try buildSFSymbols(db)

        let anchor = try adsqlRowids(db, "sf_symbols_fts", "share")
        #expect(!anchor.isEmpty)
        let scores = try adsqlScores(db, "sf_symbols_fts", "rank", "favorite")
        #expect(scores == scores.sorted())
        #expect(scores.allSatisfy { $0 < 0 })

        guard Self.sqliteHasFTS5() else { return }
        let m = try mirrorSFSymbols()

        for q in Self.sfSymbolsQueries {
            let ours = try adsqlRowids(db, "sf_symbols_fts", q)
            let theirs = try sqliteRowids(m, "sf_symbols_fts", q)
            #expect(ours == theirs, "sf_symbols_fts MATCH '\(q)': adsql \(ours.count) vs sqlite \(theirs.count)")
        }

        // Ranked top-k with explicit per-column weights — verifies bm25f matches
        // even with columnsize=0 (length-norm uses the per-doc total, kept by both).
        let weights = "4.0, 3.0, 2.0, 1.0"
        let rankCases: [(String, Int)] = [
            ("share", 40), ("favorite", 30), ("shar*", 35), ("search NOT delete", 25),
        ]
        for (q, k) in rankCases {
            let ours = try adsqlRanked(db, "sf_symbols_fts", "bm25(sf_symbols_fts, \(weights))", q, limit: k)
            let theirs = try sqliteRanked(m, "sf_symbols_fts", "bm25(sf_symbols_fts, \(weights))", q, limit: k)
            #expect(ours == theirs, "sf_symbols_fts top-\(k) bm25 '\(q)': adsql \(ours) vs sqlite \(theirs)")
            let byRank = try adsqlRanked(db, "sf_symbols_fts", "rank", q, limit: k)
            let byRankSQLite = try sqliteRanked(m, "sf_symbols_fts", "rank", q, limit: k)
            #expect(byRank == byRankSQLite, "sf_symbols_fts top-\(k) rank '\(q)'")
        }
    }

    // MARK: - Generator determinism (no SQLite needed)

    /// The generator is the parity bedrock: same (count, seed) ⇒ identical rows.
    @Test func corpusIsDeterministic() throws {
        let a = AppleDocsCorpus.generate(count: 256, seed: 0xABCD)
        let b = AppleDocsCorpus.generate(count: 256, seed: 0xABCD)
        #expect(a == b, "identical (count, seed) must reproduce the corpus")
        #expect(a.count == 256)
        #expect(a.first?.id == 1 && a.last?.id == 256, "ids are 1...count")
        let c = AppleDocsCorpus.generate(count: 256, seed: 0x1234)
        #expect(a != c, "a different seed must change the corpus")
        // Shape sanity: every field is populated (FTS columns are never empty text).
        for d in a.prefix(32) {
            #expect(!d.title.isEmpty && !d.abstract.isEmpty && !d.declaration.isEmpty)
            #expect(!d.headings.isEmpty && !d.key.isEmpty && !d.body.isEmpty)
            #expect(!d.name.isEmpty && !d.keywords.isEmpty && !d.categories.isEmpty && !d.aliases.isEmpty)
        }
    }
}
