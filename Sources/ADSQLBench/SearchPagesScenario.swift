import ADSQL
import ADSQLSearch
import CSQLite
import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// RFC 0010 §1 — the apple-docs `/search` "beat SQLite" measurement.
///
/// The apple-docs read engine ceilings at ~32 req/s under 8-way concurrency: a
/// ~28 ms `/search` query inflates ~4× under load on only ~4 of 8 cores — the
/// memory-bandwidth / cache-contention signature of 8 threads scanning the 4 GB
/// SQLite corpus (`FTS5 MATCH → JOIN documents → bm25 + tier CASE + 13 filters`).
/// ADSQL's wait-free-reader MVCC should scale with cores instead of flat-lining.
///
/// This scenario runs ADSQL's `searchPagesFramed(db, params)` (the §2.2 query +
/// §2.5 framing, the real `ad_storage_search_pages` body) against system SQLite
/// running the IDENTICAL `SearchQuery.sql` with the IDENTICAL `SearchQuery.bindings`,
/// doing framing-equivalent work (step every row, read all 24 projected columns
/// into bytes) — apples-to-apples end to end, not just MATCH. It measures:
///
///   1. single-thread per-request latency (p50/p99) for ADSQL vs SQLite,
///   2. concurrency scaling — throughput (req/s) + p99 at 1/2/4/8 reader threads
///      (ADSQL: one shared `Database`, each thread calls `searchPagesFramed`, which
///      opens its OWN wait-free MVCC `ReadTxn` snapshot per request — no shared
///      reader/statement to contend on; SQLite: one read-only connection per thread,
///      WAL) — does ADSQL scale ~linearly while SQLite flattens?
///
/// Both engines query byte-identical data (the same deterministic corpus stream).
/// NOTE: the apple-docs ceiling is at a 4 GB corpus; this synthetic corpus is
/// smaller (`--rows`, default 50k), so the memory-bandwidth effect is only
/// PARTIAL — the concurrency *trend* (scaling vs flattening) is the signal here,
/// not the absolute req/s. This is a benchmark, NOT a regression gate.
enum SearchPagesScenario {
    /// Default corpus size: large enough that the FTS postings + the `documents`
    /// row-store (wide TEXT abstract/declaration/metadata) exceed L2/L3, so
    /// concurrent scans show some memory-bandwidth effect; small enough to build
    /// in a bench setup. `--rows` tunes it.
    static let defaultRows = 50_000

    /// Top-k bound — the apple-docs `/search` page size. `ORDER BY tier, rank LIMIT`.
    static let limit: Int64 = 20

    /// Per-request iterations for the single-thread latency battery (each workload
    /// query run this many times, round-robin) — enough for a stable p50/p99
    /// without a multi-minute run.
    static let singleThreadIterations = 200

    /// Per-request iterations for the REAL-corpus single-thread battery. The 4 GB
    /// corpus answers each `/search` in ~100 ms (vs microseconds on the cache-
    /// resident synthetic corpus), so the synthetic 200 would take ~10 min; 25 is
    /// CHURN-RESISTANT — `params.count × 25` requests still give a stable p50/p99
    /// and keep the whole run to a couple of minutes.
    static let realSingleThreadIterations = 25

    /// Reader-thread counts for the scaling sweep (the RFC 0010 §1 axis).
    static let readerCounts = [1, 2, 4, 8]

    /// Wall-clock window each scaling step runs (per thread, concurrently).
    static let scalingSeconds = 2.0

    static func run(engines: [String], dir: String, config: BenchConfig) throws {
        // REAL-CORPUS mode: both `--corpus` and `--sqlite` given ⇒ skip synthetic
        // generation entirely and measure against the pre-built 4 GB databases (the
        // definitive RFC 0010 §1 measurement). The original §2.2 `searchPagesFramed`
        // is the always-present arm; `--corpus-denorm` (an ADSQL corpus with the F6
        // denorm columns) adds the `searchPagesFramedDenorm` arm — the decisive
        // "does F6 cross SQLite at real scale" measurement.
        if let adsqlPath = config.realADSQLPath, let sqlitePath = config.realSQLitePath {
            try runRealCorpus(
                adsqlPath: adsqlPath, sqlitePath: sqlitePath, denormPath: config.realDenormPath)
            return
        }

        let rows = max(1, config.rows == BenchConfig().rows ? defaultRows : config.rows)
        print("  corpus: \(rows) docs · workload: \(SearchWorkload.params.count) queries · limit \(limit)")
        print(
            "  NOTE: apple-docs' ~32 req/s ceiling is at a 4 GB corpus; this \(rows)-doc")
        print(
            "  corpus is smaller, so the memory-bandwidth effect is PARTIAL — the scaling")
        print("  TREND (linear vs flat) is the signal, not absolute req/s.")

        // Build the corpus into BOTH engines from the same deterministic stream so
        // they query byte-identical data, then keep the paths for the read passes.
        var adsqlPath: String?
        var sqlitePath: String?
        for engine in engines {
            let path = "\(dir)/search-\(engine).db"
            for suffix in ["", "-wal", "-shm", "-lock"] { unlink(path + suffix) }
            if engine == "adsql" {
                try buildADSQL(path: path, rows: rows)
                adsqlPath = path
            } else {
                guard sqliteHasFTS5() else {
                    print("  [sqlite] SKIPPED — linked sqlite3 has no FTS5 module")
                    continue
                }
                try buildSQLite(path: path, rows: rows)
                sqlitePath = path
            }
        }

        // 1. Single-thread per-request latency (p50/p99), per engine. The ADSQL arm
        // runs BOTH the original §2.2 framed path and the F6 DENORM framed path
        // (`searchPagesFramedDenorm`) so the perf gate shows the before/after on the
        // same corpus alongside the SQLite baseline.
        print("\n  -- single-thread latency (per request) --")
        if let adsqlPath { try singleThreadADSQL(path: adsqlPath, rows: rows) }
        if let sqlitePath { try singleThreadSQLite(path: sqlitePath, rows: rows) }

        // 2. Concurrency scaling: throughput + p99 at 1/2/4/8 reader threads.
        print("\n  -- concurrency scaling (\(Int(scalingSeconds))s/step, own reader per thread) --")
        print(
            "  engine   threads     req/s        p50          p99       (vs 1-thread)")
        if let adsqlPath { try scaleADSQL(path: adsqlPath, rows: rows) }
        if let sqlitePath { try scaleSQLite(path: sqlitePath, rows: rows) }
    }

    // MARK: - Real-corpus mode (RFC 0010 §1 — the 4 GB apple-docs measurement)

    /// The definitive `/search` measurement against the pre-built 4 GB corpora:
    /// ADSQL opens `adsqlPath` (read-only, wait-free MVCC), SQLite opens `sqlitePath`
    /// (read-only, one connection per worker). No synthetic generation — both engines
    /// query the SAME imported apple-docs data, so the compare is real end to end.
    /// The ORIGINAL §2.2 `searchPagesFramed` is the always-present arm; when
    /// `denormPath` is given (an ADSQL corpus carrying the F6 denorm columns), the
    /// `searchPagesFramedDenorm` arm runs too. The workload is `SearchWorkload.params`
    /// whose terms (swiftui/view/render/model/…) are real apple-docs API terms.
    static func runRealCorpus(adsqlPath: String, sqlitePath: String, denormPath: String?) throws {
        print("  REAL-CORPUS mode (RFC 0010 §1 — the definitive 4 GB measurement)")
        print("    adsql:        \(adsqlPath)")
        if let denormPath { print("    adsql-denorm: \(denormPath)") }
        print("    sqlite:       \(sqlitePath)")
        print(
            "    workload: \(SearchWorkload.params.count) queries · limit \(limit) · "
                + "single-thread iters \(realSingleThreadIterations)")

        // 0. FTS-import sanity: confirm ADSQL's imported `documents_fts` returns sane
        // row counts vs SQLite for a spread of workload terms. The CLI has no query
        // path, so this is the FIRST exercise of the imported index — if ADSQL returns
        // 0 where SQLite returns many, the import is broken: STOP and report.
        try sanityCheckRealCorpus(adsqlPath: adsqlPath, sqlitePath: sqlitePath)

        // 0b. DENORM equivalence sanity (correctness — non-negotiable): for every
        // workload query, `searchPagesFramedDenorm` on the denorm corpus must return
        // the SAME framed row count AND the SAME top docids as `searchPagesFramed`
        // (original) on the original corpus. A divergence means the denorm SOURCE was
        // built wrong (a LOWER/json mismatch); STOP and report rather than measure a
        // wrong query.
        if let denormPath {
            try denormEquivalenceCheck(originalPath: adsqlPath, denormPath: denormPath)
        }

        // 1. Single-thread per-request latency (p50/p99): original, [denorm], sqlite.
        print("\n  -- single-thread latency (per request) --")
        try singleThreadRealADSQL(path: adsqlPath)
        if let denormPath { try singleThreadRealADSQLDenorm(path: denormPath) }
        try singleThreadRealSQLite(path: sqlitePath)

        // 2. Concurrency scaling: throughput + p99 at 1/2/4/8 reader threads.
        print("\n  -- concurrency scaling (\(Int(scalingSeconds))s/step, own reader per thread) --")
        print(
            "  engine   threads     req/s        p50          p99       (vs 1-thread)")
        try scaleRealADSQL(path: adsqlPath)
        if let denormPath { try scaleRealADSQLDenorm(path: denormPath) }
        try scaleRealSQLite(path: sqlitePath)
    }

    /// Cross-corpus DENORM equivalence (RFC 0010 §2.2-2.4 "F6"): proves the denorm
    /// SOURCE was built faithfully by checking, per workload query, that
    /// `searchPagesFramedDenorm` over the denorm corpus and `searchPagesFramed` over
    /// the ORIGINAL corpus agree on (a) the framed row count and (b) the ordered list
    /// of top docids (the `path`/`d.key` column, the result identity). The two
    /// corpora are independently built, so this catches any `LOWER`/`json`/COALESCE
    /// mismatch baked into the denorm columns. Throws ``RealCorpusError`` on the
    /// first divergence so a wrong source aborts the run.
    static func denormEquivalenceCheck(originalPath: String, denormPath: String) throws {
        print("\n  -- DENORM equivalence (denorm framed == original framed: count + top docids) --")
        let original = try Database.open(
            at: originalPath,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { original.close() }
        let denorm = try Database.open(
            at: denormPath,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { denorm.close() }

        var checked = 0
        for params in SearchWorkload.params {
            let originalBytes = try searchPagesFramed(original, params)
            let denormBytes = try searchPagesFramedDenorm(denorm, params)
            let originalDocs = framedTopDocids(originalBytes)
            let denormDocs = framedTopDocids(denormBytes)
            // Row count from the §2.5 header (independent of the docid decode).
            let originalCount = framedHeaderRowCount(originalBytes)
            let denormCount = framedHeaderRowCount(denormBytes)
            guard originalCount == denormCount, originalDocs == denormDocs else {
                throw RealCorpusError.denormDiverged(
                    query: params.query,
                    originalCount: originalCount, denormCount: denormCount,
                    originalDocs: originalDocs, denormDocs: denormDocs)
            }
            checked += 1
        }
        print(
            "    OK — \(checked)/\(SearchWorkload.params.count) workload queries: denorm corpus "
                + "matches the original corpus on framed row count AND ordered top docids")
    }

    /// Per-term `documents_fts MATCH` counts for both engines (the §2.2 query's
    /// framed row count, which already reflects `MATCH + JOIN + filters + LIMIT`,
    /// plus a raw pre-LIMIT MATCH count so the candidate-set sizes are comparable).
    /// Aborts via thrown error if ADSQL is empty where SQLite is not — a broken FTS
    /// import (the read path queries `documents_fts`; a failed import would silently
    /// return nothing here even though `documents` imported fine).
    static func sanityCheckRealCorpus(adsqlPath: String, sqlitePath: String) throws {
        print("\n  -- FTS-import sanity (documents_fts MATCH row counts, adsql vs sqlite) --")
        let adsql = try Database.open(
            at: adsqlPath,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { adsql.close() }
        let sqlite = try SearchSQLiteConnection(path: sqlitePath)

        // A spread of bare anchor terms from the workload (no filters) — the clearest
        // signal that MATCH itself works on the imported index.
        let terms = ["swiftui", "view", "render", "model", "context", "buffer", "data"]
        print("    term         adsql(framed)   sqlite(framed)   adsql(match)   sqlite(match)")
        var brokenTerms: [String] = []
        for term in terms {
            let params = SearchPagesParams(query: term, raw: term, limit: limit)
            let adsqlFramed = try framedRowCount(adsql, params)
            let sqliteFramed = sqlite.frameRowCount(params)
            let adsqlMatch = try matchCountADSQL(adsql, term)
            let sqliteMatch = sqlite.matchCount(term)
            print(
                String(
                    format: "    %-10@   %12d   %14d   %12d   %13d",
                    term, adsqlFramed, sqliteFramed, adsqlMatch, sqliteMatch))
            // Broken-import guard: SQLite finds matches but ADSQL finds none.
            if sqliteMatch > 0 && adsqlMatch == 0 { brokenTerms.append(term) }
        }
        guard brokenTerms.isEmpty else {
            throw RealCorpusError.brokenFTSImport(terms: brokenTerms)
        }
        print(
            "    OK — ADSQL's documents_fts returns matches for every workload term "
                + "(import verified)")
    }

    /// Raw `documents_fts MATCH` candidate count for ADSQL (pre-LIMIT, no JOIN/filters)
    /// — the import-health signal mirrored by ``SearchSQLiteConnection/matchCount(_:)``.
    static func matchCountADSQL(_ db: Database, _ term: String) throws -> Int {
        let rows = try db.prepare("SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH ?")
            .all(.text(term))
        guard let cell = rows.first?.values.first, case .integer(let n) = cell else { return 0 }
        return Int(n)
    }

    // MARK: - Real-corpus single-thread latency (original §2.2 path only)

    static func singleThreadRealADSQL(path: String) throws {
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        // Warm: prove the workload hits non-empty results (the framing path is real).
        // No denorm equivalence guard here — the real corpus has no denorm columns.
        var warmRows = 0
        for params in SearchWorkload.params { warmRows += try framedRowCount(db, params) }
        precondition(warmRows > 0, "adsql real workload returned no rows — corpus/query mismatch")

        var original = LatencyHistogram()
        original.reserve(SearchWorkload.params.count * realSingleThreadIterations)
        for _ in 0..<realSingleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = try searchPagesFramed(db, params)
                original.record(nowNanos() - start)
                blackhole(bytes.count)
            }
        }
        print("  [adsql]  searchPagesFramed        \(original.summary())")
    }

    static func singleThreadRealSQLite(path: String) throws {
        let conn = try SearchSQLiteConnection(path: path)
        var warmRows = 0
        for params in SearchWorkload.params { warmRows += conn.frameRowCount(params) }
        precondition(warmRows > 0, "sqlite real workload returned no rows — corpus/query mismatch")

        var histogram = LatencyHistogram()
        histogram.reserve(SearchWorkload.params.count * realSingleThreadIterations)
        for _ in 0..<realSingleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = conn.frameBytes(params)
                histogram.record(nowNanos() - start)
                blackhole(bytes)
            }
        }
        print("  [sqlite] SearchQuery.sql + frame  \(histogram.summary())")
    }

    /// Single-thread latency for the F6 DENORM path (`searchPagesFramedDenorm`) on the
    /// denorm corpus. Same battery as ``singleThreadRealADSQL(path:)`` so the per-query
    /// before/after is directly comparable.
    static func singleThreadRealADSQLDenorm(path: String) throws {
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        var warmRows = 0
        for params in SearchWorkload.params {
            warmRows += framedHeaderRowCount(try searchPagesFramedDenorm(db, params))
        }
        precondition(warmRows > 0, "adsql denorm workload returned no rows — corpus/query mismatch")

        var denorm = LatencyHistogram()
        denorm.reserve(SearchWorkload.params.count * realSingleThreadIterations)
        for _ in 0..<realSingleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = try searchPagesFramedDenorm(db, params)
                denorm.record(nowNanos() - start)
                blackhole(bytes.count)
            }
        }
        print("  [adsql]  searchPagesFramedDenorm  \(denorm.summary())")
    }

    // MARK: - Real-corpus concurrency scaling (original §2.2 path only)

    static func scaleRealADSQL(path: String) throws {
        // One shared handle; each `searchPagesFramed` call opens its OWN wait-free
        // MVCC `ReadTxn` snapshot per request — the genuine per-request hot path under
        // N threads, no shared reader/statement to contend on.
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        var baseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    if let bytes = try? searchPagesFramed(db, params) { blackhole(bytes.count) }
                    histogram.record(nowNanos() - start)
                    local += 1
                }
                return local
            }
            printScaling("adsql", threads: threads, result: result, baseline: &baseline)
        }
    }

    static func scaleRealSQLite(path: String) throws {
        var baseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                // One read-only connection per thread (SQLite's supported pattern).
                guard let conn = try? SearchSQLiteConnection(path: path) else { return 0 }
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    let bytes = conn.frameBytes(params)
                    histogram.record(nowNanos() - start)
                    blackhole(bytes)
                    local += 1
                }
                return local
            }
            printScaling("sqlite", threads: threads, result: result, baseline: &baseline)
        }
    }

    /// Concurrency scaling for the F6 DENORM path on the denorm corpus — the same
    /// 1/2/4/8 sweep as ``scaleRealADSQL(path:)`` but calling `searchPagesFramedDenorm`,
    /// so the throughput table shows ADSQL(denorm) alongside ADSQL(original) + SQLite.
    static func scaleRealADSQLDenorm(path: String) throws {
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        var baseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    if let bytes = try? searchPagesFramedDenorm(db, params) { blackhole(bytes.count) }
                    histogram.record(nowNanos() - start)
                    local += 1
                }
                return local
            }
            printScaling("adsql/d", threads: threads, result: result, baseline: &baseline)
        }
    }

    // MARK: - Corpus build (ADSQL) — direct DDL, the §2.1 read schema

    static func buildADSQL(path: String, rows: Int) throws {
        let db = try Database.open(
            at: path, options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30))
        defer { db.close() }
        for sql in SearchCorpus.adsqlDDL { try db.prepare(sql).run() }
        for (slug, name) in SearchCorpus.roots {
            try db.prepare("INSERT INTO roots(slug, display_name) VALUES(?, ?)")
                .run(.text(slug), .text(name))
        }

        let buildStart = nowNanos()
        var built = 0
        var gen = SearchCorpus.Generator()
        while built < rows {
            let batchEnd = min(built + 512, rows)
            let lower = built
            try db.transaction { (tx) throws(DBError) in
                for id in (lower + 1)...batchEnd {
                    let doc = gen.next(id: Int64(id))
                    try doc.insertADSQL(tx)
                }
            }
            built = batchEnd
        }
        // Rebuild the FTS index from `documents`, exactly as the importer does (the
        // read path queries `documents_fts`, joined back to `documents` by rowid).
        try db.transaction { (tx) throws(DBError) in
            try tx.run(
                """
                INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
                SELECT id, title, abstract_text, declaration_text, headings, key FROM documents
                """)
        }
        let elapsed = nowNanos() - buildStart
        print(
            "  [adsql] corpus build    \(rows) docs in \(elapsed / 1_000_000) ms (\(formatRate(rows, elapsed)))"
        )
    }

    // MARK: - Corpus build (SQLite) — the apple-docs production pragmas

    static func buildSQLite(path: String, rows: Int) throws {
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else { throw SQLiteError.code(1, "open") }
        let db = handle
        defer { sqlite3_close_v2(db) }
        try execSQLite(db, "PRAGMA journal_mode=WAL")
        try execSQLite(db, "PRAGMA synchronous=OFF")  // build only; the read passes set NORMAL
        try execSQLite(db, "PRAGMA cache_size=-64000")
        try execSQLite(db, "PRAGMA mmap_size=10737418240")
        for sql in SearchCorpus.sqliteDDL { try execSQLite(db, sql) }
        for (slug, name) in SearchCorpus.roots {
            try execSQLite(
                db, "INSERT INTO roots(slug, display_name) VALUES('\(slug)', '\(name)')")
        }

        var insert: OpaquePointer?
        sqlite3_prepare_v3(db, SearchCorpus.sqliteInsertSQL, -1, persistent, &insert, nil)
        defer { sqlite3_finalize(insert) }

        let buildStart = nowNanos()
        var built = 0
        var gen = SearchCorpus.Generator()
        while built < rows {
            let batchEnd = min(built + 512, rows)
            try execSQLite(db, "BEGIN IMMEDIATE")
            for id in (built + 1)...batchEnd {
                let doc = gen.next(id: Int64(id))
                doc.bindSQLite(insert)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw SQLiteError.code(sqlite3_errcode(db), "insert")
                }
                sqlite3_reset(insert)
            }
            try execSQLite(db, "COMMIT")
            built = batchEnd
        }
        try execSQLite(
            db,
            """
            INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
            SELECT id, title, abstract_text, declaration_text, headings, key FROM documents
            """)
        let elapsed = nowNanos() - buildStart
        print(
            "  [sqlite] corpus build    \(rows) docs in \(elapsed / 1_000_000) ms (\(formatRate(rows, elapsed)))"
        )
    }

    // MARK: - 1. Single-thread latency

    static func singleThreadADSQL(path: String, rows: Int) throws {
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        // Warm: prove the workload hits non-empty results (the framing path is real)
        // AND that the F6 denorm path returns BYTE-IDENTICAL bytes to the original —
        // a per-run guard that the denorm arm is not silently diverging.
        var warmRows = 0
        for params in SearchWorkload.params {
            warmRows += try framedRowCount(db, params)
            let original = try searchPagesFramed(db, params)
            let denorm = try searchPagesFramedDenorm(db, params)
            precondition(
                original == denorm,
                "F6 denorm framed bytes differ from original for query='\(params.query)'")
        }
        precondition(warmRows > 0, "adsql workload returned no rows — corpus/query mismatch")

        // Original §2.2 framed path.
        var original = LatencyHistogram()
        original.reserve(SearchWorkload.params.count * singleThreadIterations)
        for _ in 0..<singleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = try searchPagesFramed(db, params)
                original.record(nowNanos() - start)
                blackhole(bytes.count)
            }
        }
        print("  [adsql]  searchPagesFramed        \(original.summary())")

        // F6 denorm framed path (`searchPagesFramedDenorm`) — the before/after arm.
        var denorm = LatencyHistogram()
        denorm.reserve(SearchWorkload.params.count * singleThreadIterations)
        for _ in 0..<singleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = try searchPagesFramedDenorm(db, params)
                denorm.record(nowNanos() - start)
                blackhole(bytes.count)
            }
        }
        print("  [adsql]  searchPagesFramedDenorm  \(denorm.summary())")
    }

    static func singleThreadSQLite(path: String, rows: Int) throws {
        let conn = try SearchSQLiteConnection(path: path)
        var warmRows = 0
        for params in SearchWorkload.params { warmRows += conn.frameRowCount(params) }
        precondition(warmRows > 0, "sqlite workload returned no rows — corpus/query mismatch")

        var histogram = LatencyHistogram()
        histogram.reserve(SearchWorkload.params.count * singleThreadIterations)
        for _ in 0..<singleThreadIterations {
            for params in SearchWorkload.params {
                let start = nowNanos()
                let bytes = conn.frameBytes(params)
                histogram.record(nowNanos() - start)
                blackhole(bytes)
            }
        }
        print("  [sqlite] SearchQuery.sql + frame  \(histogram.summary())")
    }

    // MARK: - 2. Concurrency scaling

    static func scaleADSQL(path: String, rows: Int) throws {
        // One shared handle: ADSQL readers never block — each `searchPagesFramed`
        // call opens its OWN wait-free MVCC `ReadTxn` snapshot (the §2.5 framed
        // path, same call the single-thread arm and the real `ad_storage_search_pages`
        // body use), so this is the genuine per-request hot path under N threads.
        let db = try Database.open(
            at: path,
            options: DatabaseOptions(durability: .none, maxMapSize: 32 << 30, readOnly: true))
        defer { db.close() }
        // Original §2.2 framed path.
        var baseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    if let bytes = try? searchPagesFramed(db, params) { blackhole(bytes.count) }
                    histogram.record(nowNanos() - start)
                    local += 1
                }
                return local
            }
            printScaling("adsql", threads: threads, result: result, baseline: &baseline)
        }
        // F6 denorm framed path — the same scaling axis for the before/after compare.
        var denormBaseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    if let bytes = try? searchPagesFramedDenorm(db, params) { blackhole(bytes.count) }
                    histogram.record(nowNanos() - start)
                    local += 1
                }
                return local
            }
            printScaling("adsql/d", threads: threads, result: result, baseline: &denormBaseline)
        }
    }

    static func scaleSQLite(path: String, rows: Int) throws {
        var baseline: Double = 0
        for threads in readerCounts {
            let result = runScaling(threads: threads) { stop, histogram in
                // One read-only WAL connection per thread (SQLite's supported pattern).
                guard let conn = try? SearchSQLiteConnection(path: path) else { return 0 }
                var local = 0
                var index = 0
                while !stop.isSet {
                    let params = SearchWorkload.params[index % SearchWorkload.params.count]
                    index += 1
                    let start = nowNanos()
                    let bytes = conn.frameBytes(params)
                    histogram.record(nowNanos() - start)
                    blackhole(bytes)
                    local += 1
                }
                return local
            }
            printScaling("sqlite", threads: threads, result: result, baseline: &baseline)
        }
    }

    /// Spawns `threads` workers, each running `work` (which times its own requests
    /// into the provided histogram) until the shared deadline, and returns total
    /// requests + the merged latency histogram + elapsed wall time.
    private struct ScalingResult {
        var requests: Int
        var histogram: LatencyHistogram
        var elapsedNanos: UInt64
    }

    private static func runScaling(
        threads: Int,
        work: @escaping @Sendable (StopFlag, inout LatencyHistogram) -> Int
    ) -> ScalingResult {
        let stop = StopFlag()
        let group = DispatchGroup()
        let collected = Mutex<[(Int, LatencyHistogram)]>([])
        let start = nowNanos()
        for _ in 0..<threads {
            DispatchQueue.global().async(group: group) {
                var histogram = LatencyHistogram()
                histogram.reserve(100_000)
                let count = work(stop, &histogram)
                collected.withLock { $0.append((count, histogram)) }
            }
        }
        // Run the window on this thread (a simple sleep — the workers spin).
        let deadline = start + UInt64(scalingSeconds * 1e9)
        while nowNanos() < deadline {
            let remaining = deadline &- nowNanos()
            if remaining > 0 { usleep(useconds_t(min(remaining / 1000, 20_000))) }
        }
        let elapsed = nowNanos() - start
        stop.signal()
        group.wait()
        var total = 0
        var merged = LatencyHistogram()
        collected.withLock { entries in
            for (count, histogram) in entries {
                total += count
                merged.samples.append(contentsOf: histogram.samples)
            }
        }
        return ScalingResult(requests: total, histogram: merged, elapsedNanos: elapsed)
    }

    private static func printScaling(
        _ engine: String, threads: Int, result: ScalingResult, baseline: inout Double
    ) {
        let seconds = Double(result.elapsedNanos) / 1e9
        let reqPerSec = Double(result.requests) / seconds
        if threads == 1 { baseline = reqPerSec }
        let scale = baseline > 0 ? reqPerSec / baseline : 1
        let p50 = Double(result.histogram.percentile(0.50)) / 1000
        let p99 = Double(result.histogram.percentile(0.99)) / 1000
        print(
            String(
                format: "  %-7@ %4d     %10.0f   %8.1fµs   %8.1fµs   %5.2f×",
                engine, threads, reqPerSec, p50, p99, scale))
    }

    // MARK: - Helpers

    /// The framed row count for an ADSQL request (decodes the §2.5 header's
    /// `rowCount` u32 at byte offset 4 — independent of the encoder's types).
    static func framedRowCount(_ db: Database, _ params: SearchPagesParams) throws -> Int {
        let bytes = try searchPagesFramed(db, params)
        guard bytes.count >= 8 else { return 0 }
        return Int(
            UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16)
                | (UInt32(bytes[7]) << 24))
    }

    /// The §2.5 header `rowCount` (u32 LE at byte offset 4) decoded straight from a
    /// framed buffer — used by the denorm equivalence check and the denorm warm-up.
    static func framedHeaderRowCount(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 8 else { return 0 }
        return Int(
            UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16)
                | (UInt32(bytes[7]) << 24))
    }

    /// Decodes the ordered top docids from a §2.5 framed buffer: column 0 of the
    /// §2.3 projection is `d.key AS path` (a TEXT cell), the natural result identity.
    /// Walks the full row-major cell stream (decoding each cell's length by tag) so
    /// it lands on col 0 of each row, and returns those keys in result order. Returns
    /// `[]` on any malformed/truncated buffer (treated as "no docids" — a divergence
    /// the caller will surface against the non-empty other side).
    static func framedTopDocids(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= 8 else { return [] }
        let columnCount = Int(
            UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24))
        let rowCount = framedHeaderRowCount(bytes)
        guard columnCount > 0 else { return [] }
        var offset = 8
        var docids: [String] = []
        docids.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            for col in 0..<columnCount {
                guard offset < bytes.count else { return docids }
                let tag = bytes[offset]
                offset += 1
                switch tag {
                case 0:  // NULL
                    if col == 0 { docids.append("") }
                case 1, 2:  // INT / REAL — 8-byte payload
                    if col == 0 { docids.append("") }  // col 0 is TEXT; treat as empty on shape drift
                    offset += 8
                case 3, 4:  // TEXT / BLOB — [u32 len][bytes]
                    guard offset + 4 <= bytes.count else { return docids }
                    let length = Int(
                        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24))
                    offset += 4
                    guard offset + length <= bytes.count else { return docids }
                    if col == 0 && tag == 3 {
                        docids.append(String(decoding: bytes[offset..<offset + length], as: UTF8.self))
                    } else if col == 0 {
                        docids.append("")
                    }
                    offset += length
                default:
                    return docids  // unknown tag ⇒ malformed; stop
                }
            }
        }
        return docids
    }

    static let persistent = UInt32(SQLITE_PREPARE_PERSISTENT)
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func execSQLite(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.code(sqlite3_errcode(db), sql)
        }
    }

    /// True when the linked sqlite3 has FTS5 compiled in.
    static func sqliteHasFTS5() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)", nil, nil, nil) == SQLITE_OK
    }
}

/// A shareable stop flag for the scaling workers. Wraps a noncopyable
/// `Atomic<Bool>` in a reference type so it can be captured by the per-thread
/// closures (the `Atomic` itself cannot cross a value-parameter boundary). The
/// reference is `Sendable`; the `Atomic` provides the cross-thread visibility.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func signal() { flag.store(true, ordering: .relaxed) }
}

/// Defeats dead-store elimination so the framed bytes aren't optimized away
/// (the per-row TEXT copy is exactly the cost the bench must charge for).
@inline(never)
func blackhole(_ value: Int) {
    if value == Int.min { fatalError("unreachable") }
}

/// Real-corpus failure modes — surfaced through `main.swift`'s `catch` so a broken
/// FTS import STOPS the run with a clear message instead of producing meaningless
/// latency numbers against an empty index.
enum RealCorpusError: Error, CustomStringConvertible {
    /// ADSQL's `documents_fts` returned no matches for `terms` where system SQLite
    /// returned matches — the FTS import did not populate the index.
    case brokenFTSImport(terms: [String])
    /// `searchPagesFramedDenorm` on the denorm corpus disagreed with
    /// `searchPagesFramed` on the original corpus for `query` — the denorm SOURCE
    /// was built wrong (a `LOWER`/`json`/COALESCE mismatch in an F6 column).
    case denormDiverged(
        query: String, originalCount: Int, denormCount: Int,
        originalDocs: [String], denormDocs: [String])

    var description: String {
        switch self {
        case .brokenFTSImport(let terms):
            return """
                FTS IMPORT BROKEN — ADSQL's documents_fts returned 0 rows for \
                \(terms.joined(separator: ", ")) where SQLite returned many. The \
                imported index is empty/unqueryable; aborting before producing \
                meaningless latency numbers.
                """
        case .denormDiverged(let query, let originalCount, let denormCount, let originalDocs, let denormDocs):
            return """
                DENORM SOURCE WRONG — searchPagesFramedDenorm (denorm corpus) diverged \
                from searchPagesFramed (original corpus) for query='\(query)': \
                rowCount original=\(originalCount) denorm=\(denormCount); \
                topDocids original=\(originalDocs.prefix(5)) denorm=\(denormDocs.prefix(5)). \
                A denorm column (title_lc/key_lc/year_num/track_lc/root_display/root_slug) \
                does not match its SearchDenorm semantics; aborting.
                """
        }
    }
}
