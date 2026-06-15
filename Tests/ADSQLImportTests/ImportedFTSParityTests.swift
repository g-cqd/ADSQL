import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 F2 — FTS byte-parity gate, exercised end-to-end through the importer: build a
/// SQLite corpus with a multi-column porter+unicode61 FTS5 table, import it (F1),
/// then assert that ADSQL and the source SQLite FTS5 agree, for a corpus of `MATCH`
/// queries, on (a) the **matching docid set** and (b) the **bm25 relevance score**
/// of every matching doc — under both default and apple-docs-style per-column
/// weights. Numeric score parity is the core of the swap: it proves ADSQL computes
/// the identical relevance, independent of the result *ordering*.
///
/// > Ordering parity (the exact ranked row order) additionally needs ADSQL's general
/// > bounded-top-N path to break tied scores by ascending rowid like SQLite (and like
/// > ADSQL's own WAND path already does — see `ResultPipeline.isFTSRankAscendingOrder`
/// > / `FTSWANDTopK`). A `bm25(fts, weights)` *expression* in `ORDER BY` isn't routed
/// > to WAND, so its ties currently order descending-rowid. Closing that tiebreak is
/// > the next F2/A1 engine step; this test pins the score parity it builds on.
@Suite("Imported FTS bm25 parity")
struct ImportedFTSParityTests {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @Test func bm25ScoresMatchSQLiteFTS5() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let sourcePath = dir.file("corpus.db")

        var src: OpaquePointer?
        try #require(
            sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK)
        defer { sqlite3_close_v2(src) }
        try exec(src, "CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT, abstract TEXT)")

        // 24 docs with varied term frequencies + lengths, so bm25 produces a spread of
        // (and some equal) scores — the parity that matters.
        let words = ["swift", "uikit", "combine", "metal", "swiftui", "view", "data", "async"]
        for i in 1...24 {
            let a = words[i % words.count]
            let b = words[(i * 3 + 1) % words.count]
            let c = words[(i * 5 + 2) % words.count]
            let title = "\(a) \(b) guide"
            let extra = i % 3 == 0 ? " \(a) deep dive" : ""
            let abstract = "learn \(a) with \(b) and \(c) using \(i % 2 == 0 ? "advanced" : "basic") patterns\(extra)"
            try exec(
                src,
                "INSERT INTO documents(id, title, abstract) VALUES (\(i), '\(title)', '\(abstract)')")
        }
        try exec(
            src, "CREATE VIRTUAL TABLE documents_fts USING fts5(title, abstract, tokenize='porter unicode61')")
        try exec(src, "INSERT INTO documents_fts(rowid, title, abstract) SELECT id, title, abstract FROM documents")

        let manifest = ImportManifest(ftsTables: [
            .init(
                name: "documents_fts", columns: ["title", "abstract"],
                tokenize: ["porter", "unicode61"],
                source: .init(table: "documents", columns: ["title", "abstract"]))
        ])
        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: sourcePath, manifest: manifest)

        let queries = ["swift", "uikit", "advanced", "patterns", "view", "data", "async", "basic"]
        // Default (all-ones) and apple-docs-style weighted (title 2×, abstract 1×).
        for weightSpec in ["1.0, 1.0", "2.0, 1.0"] {
            for query in queries {
                let ours = try adsqlScores(db, query, weights: weightSpec)
                let theirs = sqliteScores(src, query, weights: weightSpec)
                #expect(
                    Set(ours.keys) == Set(theirs.keys),
                    "bm25(\(weightSpec)) MATCH '\(query)': docid sets differ — \(Set(ours.keys)) vs \(Set(theirs.keys))"
                )
                for (docid, theirScore) in theirs {
                    let ourScore = ours[docid] ?? .nan
                    let tolerance = 1e-9 * Swift.max(abs(theirScore), 1)
                    #expect(
                        abs(ourScore - theirScore) <= tolerance,
                        "bm25(\(weightSpec)) score for \(docid) on '\(query)': adsql \(ourScore) vs sqlite \(theirScore)"
                    )
                }
            }
        }
    }

    /// ADSQL: docid → bm25 relevance (no ORDER BY — pure membership + score).
    private func adsqlScores(_ db: Database, _ query: String, weights: String) throws -> [Int64: Double] {
        var scores: [Int64: Double] = [:]
        for row in try db.prepare(
            "SELECT rowid, bm25(documents_fts, \(weights)) FROM documents_fts WHERE documents_fts MATCH ?"
        ).all(.text(query)) {
            guard case .integer(let docid) = row[0], case .real(let score) = row[1] else { continue }
            scores[docid] = score
        }
        return scores
    }

    /// SQLite FTS5 oracle: docid → bm25 relevance for the same query + weights.
    private func sqliteScores(_ db: OpaquePointer?, _ query: String, weights: String) -> [Int64: Double] {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT rowid, bm25(documents_fts, \(weights)) FROM documents_fts WHERE documents_fts MATCH ?",
                -1, &stmt, nil) == SQLITE_OK
        else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, transient)
        var scores: [Int64: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            scores[sqlite3_column_int64(stmt, 0)] = sqlite3_column_double(stmt, 1)
        }
        return scores
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
    }
}
