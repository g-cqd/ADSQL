import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 F2 — FTS byte-parity gate, exercised end-to-end through the importer: build a
/// SQLite corpus with a multi-column porter+unicode61 FTS5 table, import it (F1),
/// then assert ADSQL and the source SQLite FTS5 agree, for a corpus of `MATCH`
/// queries (under default and apple-docs-style per-column weights), on:
///   1. the **matching docid set** + the **numeric bm25 relevance** of every match
///      (ADSQL computes byte-identical scores), and
///   2. the **ranked row order** of `ORDER BY <rank>` with **no explicit rowid
///      tiebreak** — including ties, which now order ascending-rowid like SQLite
///      (the bounded-top-N upper-bound insert fix), matching the WAND path.
@Suite("Imported FTS bm25 parity")
struct ImportedFTSParityTests {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let queries = ["swift", "uikit", "advanced", "patterns", "view", "data", "async", "basic"]

    @Test func scoresAndRankedOrderMatchSQLiteFTS5() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let sourcePath = dir.file("corpus.db")

        var src: OpaquePointer?
        try #require(
            sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK)
        defer { sqlite3_close_v2(src) }
        try exec(src, "CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT, abstract TEXT)")

        // 24 docs with varied term frequencies + lengths — a spread of bm25 scores
        // plus deliberate ties (many docs share a term once), the order that matters.
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

        // Default (all-ones) and apple-docs-style weighted (title 2×, abstract 1×).
        for weights in ["1.0, 1.0", "2.0, 1.0"] {
            for query in queries {
                // 1. Score parity (membership + per-doc bm25).
                let ourScores = try adsqlScores(db, query, weights: weights)
                let theirScores = sqliteScores(src, query, weights: weights)
                #expect(
                    Set(ourScores.keys) == Set(theirScores.keys),
                    "bm25(\(weights)) MATCH '\(query)': docid sets differ")
                for (docid, theirScore) in theirScores {
                    let ourScore = ourScores[docid] ?? .nan
                    #expect(
                        abs(ourScore - theirScore) <= 1e-9 * Swift.max(abs(theirScore), 1),
                        "bm25(\(weights)) score for \(docid) on '\(query)': adsql \(ourScore) vs sqlite \(theirScore)"
                    )
                }

                // 2. Ranked-order parity (no explicit rowid tiebreak — the apple-docs shape).
                let ourOrder = try db.prepare(
                    """
                    SELECT rowid, bm25(documents_fts, \(weights)) AS rank
                    FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rank LIMIT 10
                    """
                ).all(.text(query)).map { $0[0] }
                let theirOrder = sqliteRanked(src, query, orderBy: "bm25(documents_fts, \(weights))").map {
                    Value.integer($0)
                }
                #expect(
                    ourOrder == theirOrder,
                    "bm25(\(weights)) order MATCH '\(query)': adsql \(ourOrder) vs sqlite \(theirOrder)")
            }
        }
    }

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

    private func sqliteRanked(_ db: OpaquePointer?, _ query: String, orderBy: String) -> [Int64] {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ? ORDER BY \(orderBy) LIMIT 10",
                -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, transient)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
    }
}
