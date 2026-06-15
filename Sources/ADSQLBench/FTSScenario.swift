import ADSQL
import CSQLite
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// F6b — the FTS *measurement* slice. FTS is already correctness-complete and
/// SQLite-FTS5-parity-verified (F6a); this benchmarks the apple-docs
/// ranked-search shape against real SQLite FTS5 on three axes:
///
///   1. index-build throughput (rows/s) — INSERT N docs into `documents_fts`,
///   2. MATCH p50 — membership queries (single term / AND / OR / prefix),
///   3. ranked top-k p50 — `ORDER BY bm25(documents_fts,10,5,3,2,1) LIMIT 20`.
///
/// This baseline DATA-DRIVES the later perf slices (F6c block-max WAND, F6d
/// segments/merge). No engine tuning happens here — bench only.
///
/// ADSQL's `FTSIndex` stores postings one block per key (F6d): appending a
/// document rewrites only the last block, so the build is O(n) — not the pre-F6d
/// O(n²) whole-list re-encode. Larger corpora are now feasible; `rowCap` bounds a
/// bare run and `--rows` tunes it. The build still trails FTS5 by a roughly
/// constant factor, and MATCH latency is dominated by decoding very common terms'
/// long lists (the F6e codec signal); ranked top-k uses block-max WAND (F6c).
enum FTSScenario {
    /// Corpus-size clamp. `--rows` is clamped to this; a bare run (BenchConfig
    /// defaults rows to 200k) and `--full` land here. F6d's O(n) build makes this
    /// size finish in seconds — pre-F6d an 8k build took >3 min; now ≈3 s. Pre-F6d
    /// build curve, for reference: 500→0.30s · 1k→1.1s · 2k→4.7s · 4k→16.7s ·
    /// 5k>60s (super-O(n²)); F6d is ~linear (≈ constant rows/s across sizes).
    /// SQLite FTS5 builds at ≈100k rows/s.
    static let rowCap = 8_000

    /// The apple-docs headline shape — identical DDL/tokenizer/weights on both
    /// engines. `bm25(documents_fts, 10, 5, 3, 2, 1)` weights title heaviest.
    static let ddl = """
        CREATE VIRTUAL TABLE documents_fts USING fts5(
          title, abstract, declaration, headings, key, tokenize='porter unicode61')
        """
    static let bm25 = "bm25(documents_fts, 10.0, 5.0, 3.0, 2.0, 1.0)"
    /// A second, abstract/declaration-heavy weight vector — exercises **bm25f**
    /// per-column weighting with a ranking distinct from `bm25` (title-heavy), so
    /// the bench measures the weighted-rank path and not just the default profile.
    /// Ordering parity vs SQLite FTS5 under weighted bm25() is covered by
    /// `FTSParityTests`; this arm measures its latency on both engines.
    static let bm25fWeighted = "bm25(documents_fts, 1.0, 8.0, 6.0, 1.0, 1.0)"

    /// R6 — a second FTS shape: the **trigram** tokenizer indexes 3-grams, so MATCH
    /// finds arbitrary substrings (LIKE-style), not whole tokens. Same columns/corpus
    /// as `documents_fts`; the bench measures its build + substring-MATCH latency
    /// against SQLite FTS5's trigram on both engines.
    static let trigramDDL = """
        CREATE VIRTUAL TABLE documents_trigram USING fts5(
          title, abstract, declaration, headings, key, tokenize='trigram')
        """
    /// Substring probes (≥3 chars — trigram's minimum gram) hitting mid-token spans
    /// a token tokenizer could not: e.g. "igur" inside "configures", " flow".
    static let trigramQueries = ["view", "render", "igur", "swiftu", "eleg", " data"]
    /// Churn arm: 1/`churnDivisor` of the built corpus is deleted and re-inserted
    /// after the initial build, measuring the FTS edit/re-index path (rows/s).
    static let churnDivisor = 8

    /// Representative MATCH battery, drawn from the generator vocabulary so each
    /// hits a meaningful, varied subset: single anchor term, stemmed prose term,
    /// AND, OR, prefix, and one column-filtered query.
    static let matchQueries = [
        "swiftui",  // single high-frequency anchor term
        "rendering",  // porter-stemmed prose term
        "view AND model",  // AND (intersection)
        "swiftui OR uikit",  // OR (union)
        "render*",  // prefix expansion
        "title:swiftui",  // column-filtered
    ]

    /// Ranked top-k probes (the headline `ORDER BY bm25 LIMIT 20` shape). A mix of
    /// single-term, OR, and prefix so the ranker sees differently-sized candidate
    /// sets.
    static let rankedQueries = ["view", "swiftui OR uikit", "render*", "metal"]

    static let limit = 20
    /// Per-query latency iterations (each query run this many times round-robin).
    /// Kept modest: ADSQL ranked top-k for a near-universal term (e.g. "view")
    /// scores most of the corpus today, so it is tens-of-ms at the default 2k size
    /// — 100 reps per query gives a stable p50 without a multi-minute bench. (The
    /// expense itself is the F6c WAND signal; this is a latency bench, not a stress
    /// loop.)
    static let iterationsPerQuery = 100

    static func run(_ engine: String, dir: String, config: BenchConfig) throws {
        let rows = min(config.rows, rowCap)
        let path = "\(dir)/fts-\(engine).db"
        for suffix in ["", "-wal", "-shm", "-lock"] { unlink(path + suffix) }
        if engine == "adsql" {
            try runADSQL(path: path, rows: rows, config: config)
        } else {
            try runSQLite(path: path, rows: rows, config: config)
        }
    }

    // MARK: - ADSQL (FTS5 SQL surface)

    static func runADSQL(path: String, rows: Int, config: BenchConfig) throws {
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(
                durability: .none, maxMapSize: 32 << 30,
                execution: ExecutionOptions(evaluator: config.evaluator, join: config.joinStrategy)))
        defer { db.close() }
        try db.prepare(ddl).run()

        // 1. Index build — direct multi-column INSERT into the FTS table, one
        // transaction per batch (the apple-docs write path; the trigger path adds
        // base-table DML overhead we do not want to charge the index build with).
        let buildStart = nowNanos()
        var built = 0
        var gen = FTSCorpus.Generator()
        while built < rows {
            let batchEnd = min(built + 256, rows)
            let lower = built
            try db.transaction { (tx) throws(DBError) in
                for id in (lower + 1)...batchEnd {
                    let doc = gen.next(id: Int64(id))
                    try tx.run(
                        "INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key) VALUES(?, ?, ?, ?, ?, ?)",
                        .integer(doc.id), .text(doc.title), .text(doc.abstract),
                        .text(doc.declaration), .text(doc.headings), .text(doc.key))
                }
            }
            built = batchEnd
        }
        let buildElapsed = nowNanos() - buildStart
        print(
            "  [adsql] fts build       \(rows) docs in \(buildElapsed / 1_000_000) ms (\(formatRate(rows, buildElapsed)))"
        )

        // Count-sanity: an anchor term must hit a non-empty, bounded set (parity is
        // already proven by F6a; this only guards against an empty/degenerate index).
        let anchorCount = try db.prepare(
            "SELECT count(*) FROM documents_fts WHERE documents_fts MATCH ?"
        ).all(.text("swiftui"))
        if case .integer(let n) = anchorCount[0][0] {
            precondition(n > 0 && n <= Int64(rows), "anchor MATCH count out of range: \(n)")
        }

        // 2. MATCH p50 — membership only (project rowid, drain the result).
        let matchStmt = try db.prepare(
            "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?")
        var matchHist = LatencyHistogram()
        matchHist.reserve(matchQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in matchQueries {
                let start = nowNanos()
                let result = try matchStmt.all(.text(q))
                matchHist.record(nowNanos() - start)
                precondition(result.count <= rows)
            }
        }
        print("  [adsql] fts MATCH       \(matchHist.summary())")

        // 3. Ranked top-k p50 — the headline ranked-search shape.
        let rankedStmt = try db.prepare(
            """
            SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?
            ORDER BY \(bm25) LIMIT \(limit)
            """)
        var rankedHist = LatencyHistogram()
        rankedHist.reserve(rankedQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in rankedQueries {
                let start = nowNanos()
                let result = try rankedStmt.all(.text(q))
                rankedHist.record(nowNanos() - start)
                precondition(result.count <= limit)
            }
        }
        print("  [adsql] fts ranked@\(limit)   \(rankedHist.summary())")

        // 3b. Ranked top-k under a different bm25f weight vector (abstract/declaration
        // heavy) — measures the weighted-rank path; ordering parity is in FTSParityTests.
        let rankedFStmt = try db.prepare(
            """
            SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?
            ORDER BY \(bm25fWeighted) LIMIT \(limit)
            """)
        var rankedFHist = LatencyHistogram()
        rankedFHist.reserve(rankedQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in rankedQueries {
                let start = nowNanos()
                let result = try rankedFStmt.all(.text(q))
                rankedFHist.record(nowNanos() - start)
                precondition(result.count <= limit)
            }
        }
        print("  [adsql] fts bm25f@\(limit)    \(rankedFHist.summary())")

        // 4. R6 — trigram tokenizer (substring search). Same corpus under a trigram
        // tokenizer; MATCH finds arbitrary substrings, so the probes hit mid-token
        // spans a token tokenizer cannot.
        try db.prepare(trigramDDL).run()
        var trigramGen = FTSCorpus.Generator()
        var tgBuilt = 0
        while tgBuilt < rows {
            let batchEnd = min(tgBuilt + 256, rows)
            let lower = tgBuilt
            try db.transaction { (tx) throws(DBError) in
                for id in (lower + 1)...batchEnd {
                    let doc = trigramGen.next(id: Int64(id))
                    try tx.run(
                        "INSERT INTO documents_trigram(rowid, title, abstract, declaration, headings, key) VALUES(?, ?, ?, ?, ?, ?)",
                        .integer(doc.id), .text(doc.title), .text(doc.abstract),
                        .text(doc.declaration), .text(doc.headings), .text(doc.key))
                }
            }
            tgBuilt = batchEnd
        }
        let trigramMatch = try db.prepare(
            "SELECT rowid FROM documents_trigram WHERE documents_trigram MATCH ?")
        var trigramHist = LatencyHistogram()
        trigramHist.reserve(trigramQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in trigramQueries {
                let start = nowNanos()
                let result = try trigramMatch.all(.text(q))
                trigramHist.record(nowNanos() - start)
                precondition(result.count <= rows)
            }
        }
        print("  [adsql] fts trigram     \(trigramHist.summary())")

        // 5. R6 — update/delete churn: delete 1/churnDivisor of the corpus, then
        // re-insert the same docs (the FTS edit/re-index path), measured as rows/s.
        let churn = max(1, rows / churnDivisor)
        let churnStart = nowNanos()
        try db.transaction { (tx) throws(DBError) in
            for id in 1...churn { try tx.run("DELETE FROM documents_fts WHERE rowid = ?", .integer(Int64(id))) }
        }
        var churnGen = FTSCorpus.Generator()
        try db.transaction { (tx) throws(DBError) in
            for id in 1...churn {
                let doc = churnGen.next(id: Int64(id))
                try tx.run(
                    "INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key) VALUES(?, ?, ?, ?, ?, ?)",
                    .integer(doc.id), .text(doc.title), .text(doc.abstract),
                    .text(doc.declaration), .text(doc.headings), .text(doc.key))
            }
        }
        let churnElapsed = nowNanos() - churnStart
        print(
            "  [adsql] fts churn       \(churn) del+ins in \(churnElapsed / 1_000_000) ms (\(formatRate(churn * 2, churnElapsed)))"
        )
    }

    // MARK: - SQLite FTS5 baseline

    static func runSQLite(path: String, rows: Int, config: BenchConfig) throws {
        guard sqliteHasFTS5() else {
            print("  [sqlite] fts SKIPPED — linked sqlite3 has no FTS5 module")
            return
        }

        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else { throw SQLiteError.code(1, "open") }
        let db = handle
        defer { sqlite3_close_v2(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.code(sqlite3_errcode(db), sql)
            }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=OFF")
        try exec("PRAGMA cache_size=-64000")
        try exec("PRAGMA mmap_size=10737418240")
        try exec(ddl)

        // 1. Index build.
        var insert: OpaquePointer?
        sqlite3_prepare_v3(
            db,
            "INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &insert, nil)
        defer { sqlite3_finalize(insert) }

        let buildStart = nowNanos()
        var built = 0
        var gen = FTSCorpus.Generator()
        while built < rows {
            let batchEnd = min(built + 256, rows)
            try exec("BEGIN IMMEDIATE")
            for id in (built + 1)...batchEnd {
                let doc = gen.next(id: Int64(id))
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, doc.id)
                sqlite3_bind_text(insert, 2, doc.title, -1, transient)
                sqlite3_bind_text(insert, 3, doc.abstract, -1, transient)
                sqlite3_bind_text(insert, 4, doc.declaration, -1, transient)
                sqlite3_bind_text(insert, 5, doc.headings, -1, transient)
                sqlite3_bind_text(insert, 6, doc.key, -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw SQLiteError.code(sqlite3_errcode(db), "insert")
                }
            }
            try exec("COMMIT")
            built = batchEnd
        }
        let buildElapsed = nowNanos() - buildStart
        print(
            "  [sqlite] fts build       \(rows) docs in \(buildElapsed / 1_000_000) ms (\(formatRate(rows, buildElapsed)))"
        )

        // Count-sanity.
        var countStmt: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT count(*) FROM documents_fts WHERE documents_fts MATCH ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &countStmt, nil)
        sqlite3_bind_text(countStmt, 1, "swiftui", -1, transient)
        precondition(sqlite3_step(countStmt) == SQLITE_ROW)
        let anchorCount = sqlite3_column_int64(countStmt, 0)
        precondition(anchorCount > 0 && anchorCount <= Int64(rows), "anchor MATCH count out of range")
        sqlite3_finalize(countStmt)

        // 2. MATCH p50.
        var matchStmt: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &matchStmt, nil)
        defer { sqlite3_finalize(matchStmt) }
        var matchHist = LatencyHistogram()
        matchHist.reserve(matchQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in matchQueries {
                let start = nowNanos()
                sqlite3_reset(matchStmt)
                sqlite3_bind_text(matchStmt, 1, q, -1, transient)
                while sqlite3_step(matchStmt) == SQLITE_ROW {}
                matchHist.record(nowNanos() - start)
            }
        }
        print("  [sqlite] fts MATCH       \(matchHist.summary())")

        // 3. Ranked top-k p50.
        var rankedStmt: OpaquePointer?
        sqlite3_prepare_v3(
            db,
            "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?1 ORDER BY \(bm25) LIMIT \(limit)",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &rankedStmt, nil)
        defer { sqlite3_finalize(rankedStmt) }
        var rankedHist = LatencyHistogram()
        rankedHist.reserve(rankedQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in rankedQueries {
                let start = nowNanos()
                sqlite3_reset(rankedStmt)
                sqlite3_bind_text(rankedStmt, 1, q, -1, transient)
                while sqlite3_step(rankedStmt) == SQLITE_ROW {}
                rankedHist.record(nowNanos() - start)
            }
        }
        print("  [sqlite] fts ranked@\(limit)   \(rankedHist.summary())")

        // 3b. Ranked top-k under the bm25f weight vector (mirrors the ADSQL arm).
        var rankedFStmt: OpaquePointer?
        sqlite3_prepare_v3(
            db,
            "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?1 ORDER BY \(bm25fWeighted) LIMIT \(limit)",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &rankedFStmt, nil)
        defer { sqlite3_finalize(rankedFStmt) }
        var rankedFHist = LatencyHistogram()
        rankedFHist.reserve(rankedQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in rankedQueries {
                let start = nowNanos()
                sqlite3_reset(rankedFStmt)
                sqlite3_bind_text(rankedFStmt, 1, q, -1, transient)
                while sqlite3_step(rankedFStmt) == SQLITE_ROW {}
                rankedFHist.record(nowNanos() - start)
            }
        }
        print("  [sqlite] fts bm25f@\(limit)    \(rankedFHist.summary())")

        // 4. R6 — trigram tokenizer (mirrors the ADSQL arm).
        try exec(trigramDDL)
        var tgInsert: OpaquePointer?
        sqlite3_prepare_v3(
            db,
            "INSERT INTO documents_trigram(rowid, title, abstract, declaration, headings, key) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &tgInsert, nil)
        defer { sqlite3_finalize(tgInsert) }
        var trigramGen = FTSCorpus.Generator()
        var tgBuilt = 0
        while tgBuilt < rows {
            let batchEnd = min(tgBuilt + 256, rows)
            try exec("BEGIN IMMEDIATE")
            for id in (tgBuilt + 1)...batchEnd {
                let doc = trigramGen.next(id: Int64(id))
                sqlite3_reset(tgInsert)
                sqlite3_bind_int64(tgInsert, 1, doc.id)
                sqlite3_bind_text(tgInsert, 2, doc.title, -1, transient)
                sqlite3_bind_text(tgInsert, 3, doc.abstract, -1, transient)
                sqlite3_bind_text(tgInsert, 4, doc.declaration, -1, transient)
                sqlite3_bind_text(tgInsert, 5, doc.headings, -1, transient)
                sqlite3_bind_text(tgInsert, 6, doc.key, -1, transient)
                guard sqlite3_step(tgInsert) == SQLITE_DONE else {
                    throw SQLiteError.code(sqlite3_errcode(db), "trigram insert")
                }
            }
            try exec("COMMIT")
            tgBuilt = batchEnd
        }
        var tgMatch: OpaquePointer?
        sqlite3_prepare_v3(
            db, "SELECT rowid FROM documents_trigram WHERE documents_trigram MATCH ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &tgMatch, nil)
        defer { sqlite3_finalize(tgMatch) }
        var trigramHist = LatencyHistogram()
        trigramHist.reserve(trigramQueries.count * iterationsPerQuery)
        for _ in 0..<iterationsPerQuery {
            for q in trigramQueries {
                let start = nowNanos()
                sqlite3_reset(tgMatch)
                sqlite3_bind_text(tgMatch, 1, q, -1, transient)
                while sqlite3_step(tgMatch) == SQLITE_ROW {}
                trigramHist.record(nowNanos() - start)
            }
        }
        print("  [sqlite] fts trigram     \(trigramHist.summary())")

        // 5. R6 — update/delete churn (mirrors the ADSQL arm).
        let churn = max(1, rows / churnDivisor)
        let churnStart = nowNanos()
        var del: OpaquePointer?
        sqlite3_prepare_v3(
            db, "DELETE FROM documents_fts WHERE rowid = ?1",
            -1, UInt32(SQLITE_PREPARE_PERSISTENT), &del, nil)
        defer { sqlite3_finalize(del) }
        try exec("BEGIN IMMEDIATE")
        for id in 1...churn {
            sqlite3_reset(del)
            sqlite3_bind_int64(del, 1, Int64(id))
            guard sqlite3_step(del) == SQLITE_DONE else {
                throw SQLiteError.code(sqlite3_errcode(db), "churn delete")
            }
        }
        try exec("COMMIT")
        var churnGen = FTSCorpus.Generator()
        try exec("BEGIN IMMEDIATE")
        for id in 1...churn {
            let doc = churnGen.next(id: Int64(id))
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, doc.id)
            sqlite3_bind_text(insert, 2, doc.title, -1, transient)
            sqlite3_bind_text(insert, 3, doc.abstract, -1, transient)
            sqlite3_bind_text(insert, 4, doc.declaration, -1, transient)
            sqlite3_bind_text(insert, 5, doc.headings, -1, transient)
            sqlite3_bind_text(insert, 6, doc.key, -1, transient)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw SQLiteError.code(sqlite3_errcode(db), "churn insert")
            }
        }
        try exec("COMMIT")
        let churnElapsed = nowNanos() - churnStart
        print(
            "  [sqlite] fts churn       \(churn) del+ins in \(churnElapsed / 1_000_000) ms (\(formatRate(churn * 2, churnElapsed)))"
        )
    }

    /// True when the linked sqlite3 has FTS5 compiled in (create a throwaway fts5
    /// table in memory; on failure the SQLite side is skipped, ADSQL-only output).
    static func sqliteHasFTS5() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)", nil, nil, nil) == SQLITE_OK
    }
}

/// Self-contained, deterministic apple-docs-SHAPED corpus generator — lives IN
/// ADSQLBench because the bench target depends only on `["ADSQL", "CSQLite"]`
/// and cannot import `AppleDocsCorpus` (that's in the test-support target). This
/// is a faithful, independent reimplementation of the F6a generator's shape:
/// tech-documentation vocabulary across title/abstract/declaration/headings/key,
/// driven by a seeded SplitMix64 stream (no Foundation `random`/clock), so the
/// same `id`/seed produces byte-identical rows on every run and machine. The two
/// engines build from the SAME stream (a fresh `Generator()` each), so they
/// index identical text. (Mirrors `Tests/ADSQLTestSupport/AppleDocsCorpus.swift`;
/// not imported — see the brief's dependency constraint.)
enum FTSCorpus {
    struct Document {
        let id: Int64
        let title: String
        let abstract: String
        let declaration: String
        let headings: String
        let key: String
    }

    // Fixed vocabulary, indexed by the seeded stream (same shape as the F6a corpus
    // so single terms hit a meaningful fraction and bm25 ranking discriminates).
    static let frameworks = [
        "SwiftUI", "UIKit", "AppKit", "Foundation", "Combine", "CoreData",
        "Metal", "CoreML", "CloudKit", "AVFoundation", "MapKit", "StoreKit",
        "WidgetKit", "SwiftData", "Observation", "CoreGraphics", "Vision",
        "ARKit", "RealityKit", "CoreLocation",
    ]
    static let typeStems = [
        "Async", "Navigation", "Scroll", "Stack", "Grid", "List", "Text",
        "Image", "Button", "Toggle", "Picker", "Gesture", "Animation",
        "Layout", "Render", "Query", "Model", "Store", "Session", "Stream",
        "Buffer", "Texture", "Pipeline", "Descriptor", "Coordinate",
    ]
    static let typeRoles = [
        "View", "Controller", "Manager", "Provider", "Builder", "Context",
        "Configuration", "Delegate", "Coordinator", "Renderer", "Reader",
        "Writer", "Cache", "Registry", "Resolver",
    ]
    static let proseVerbs = [
        "renders", "configures", "manages", "observes", "encodes", "decodes",
        "schedules", "animates", "loads", "caches", "fetches", "presents",
        "computes", "transforms", "synchronizes", "validates", "resolves",
    ]
    static let proseNouns = [
        "view", "value", "model", "context", "buffer", "texture", "request",
        "response", "gesture", "layout", "pipeline", "snapshot", "transaction",
        "subscription", "coordinate", "descriptor", "hierarchy",
    ]
    static let proseAdjectives = [
        "structured", "concurrent", "declarative", "immutable", "lazy", "shared",
        "observable", "asynchronous", "composable", "reusable", "deterministic",
    ]
    static let headingWords = [
        "Overview", "Topics", "Declaration", "Discussion", "Parameters",
        "Return Value", "See Also", "Mentioned in", "Availability", "Conforms To",
    ]

    /// Deterministic apple-docs row stream. A fresh `Generator()` replays the same
    /// rows; both engines use one each so they index byte-identical text. Uses the
    /// same SplitMix64 constants as the test-support `SplitMix64` (no Foundation).
    struct Generator {
        private var state: UInt64 = 0xF6B_C0FFEE

        private mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        private mutating func pick(_ array: [String]) -> String {
            array[Int(next() % UInt64(array.count))]
        }

        private mutating func sentence() -> String {
            "\(pick(FTSCorpus.proseAdjectives)) \(pick(FTSCorpus.proseNouns)) \(pick(FTSCorpus.proseVerbs)) the \(pick(FTSCorpus.proseNouns))"
        }

        mutating func next(id: Int64) -> Document {
            let framework = pick(FTSCorpus.frameworks)
            let typeName = pick(FTSCorpus.typeStems) + pick(FTSCorpus.typeRoles)
            let title = "\(framework) \(typeName)"
            let abstract = sentence() + " " + sentence()
            let kind = ["struct", "final class", "enum", "actor"][Int(next() % 4)]
            let role = pick(FTSCorpus.typeRoles)
            let declaration = "\(kind) \(typeName) conforms to \(role) in \(framework)"
            let headingCount = 2 + Int(next() % 2)
            let headings = (0..<headingCount).map { _ in pick(FTSCorpus.headingWords) }
                .joined(separator: " ")
            let key = "doc/\(framework.lowercased())/\(typeName.lowercased())/\(id)"
            return Document(
                id: id, title: title, abstract: abstract, declaration: declaration,
                headings: headings, key: key)
        }
    }
}
