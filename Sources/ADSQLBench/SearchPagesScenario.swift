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

    /// Reader-thread counts for the scaling sweep (the RFC 0010 §1 axis).
    static let readerCounts = [1, 2, 4, 8]

    /// Wall-clock window each scaling step runs (per thread, concurrently).
    static let scalingSeconds = 2.0

    static func run(engines: [String], dir: String, config: BenchConfig) throws {
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
