import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// M5 / F6c — block-max WAND ranked top-k. WAND is a pure optimization: a ranked
/// `ORDER BY rank/bm25(…) LIMIT k` over an eligible query (single term, or AND/OR
/// of terms) must return the IDENTICAL top-k — same rowids, same order — as the
/// score-all path. These tests pin that invariant WITHOUT needing SQLite by
/// differencing two ADSQL paths on the same data:
///
///   - WAND path:      `ORDER BY rank LIMIT k`            (single-table ⇒ routed to WAND)
///   - score-all path: `ORDER BY rank` then `prefix(k)`   (no LIMIT ⇒ no WAND)
///
/// The score-all order is itself the F4 path the F6a parity suite proves equal to
/// SQLite FTS5, so equality here chains WAND ⟷ score-all ⟷ FTS5. The suite also
/// covers the eligibility boundary (prefix / phrase / NOT / column filters fall
/// back, still correct) and edge cases (k ≥ match count, ties, AND with a missing
/// term).
@Suite("FTS5 — F6c block-max WAND ranked top-k")
struct FTSWANDTests {
    /// A corpus dense and varied enough that a single common term spans several
    /// posting blocks (blockSize = 128) and bm25 ordering is non-trivial: term
    /// frequencies, field placement, and lengths all vary by docid. 400 docs ⇒ the
    /// "alpha" list (≈ every doc) is 3–4 blocks, exercising block-max skipping.
    private func build(_ db: Database, count: Int = 400) throws {
        try db.prepare(
            "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')"
        ).run()
        let insert = try db.prepare("INSERT INTO fts(rowid, title, body) VALUES(?, ?, ?)")
        for i in 1...count {
            // "alpha" is near-universal (varying tf); "beta"/"gamma" are medium; "rare"
            // is sparse. Field placement varies so title-weighting can reorder.
            let alphas = String(repeating: "alpha ", count: 1 + (i % 4))
            let title = (i % 3 == 0) ? "alpha beta" : (i % 3 == 1 ? "gamma title" : "delta")
            var body = "\(alphas)value renders the buffer \(i)"
            if i % 5 == 0 { body += " beta beta" }
            if i % 7 == 0 { body += " gamma" }
            if i % 50 == 0 { body += " rare rare rare" }
            try insert.run(.integer(Int64(i)), .text(title), .text(body))
        }
    }

    /// Top-k rowids via the WAND path (`ORDER BY <expr>, rowid LIMIT k`).
    private func wandTopK(
        _ db: Database, _ orderExpr: String, _ query: String, k: Int
    ) throws -> [Int64] {
        try db.prepare(
            "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY \(orderExpr), rowid LIMIT \(k)"
        ).all(.text(query)).map { row in
            guard case .integer(let id) = row[0] else { return Int64(-1) }
            return id
        }
    }

    /// Full ranked order via the score-all path (`ORDER BY <expr>, rowid`, no LIMIT).
    private func scoreAllOrder(
        _ db: Database, _ orderExpr: String, _ query: String
    ) throws -> [Int64] {
        try db.prepare(
            "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY \(orderExpr), rowid"
        ).all(.text(query)).map { row in
            guard case .integer(let id) = row[0] else { return Int64(-1) }
            return id
        }
    }

    // MARK: - WAND == score-all (the core invariant)

    @Test func wandMatchesScoreAllSingleTerm() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wand1.adsql"))
        defer { db.close() }
        try build(db)

        // The near-universal term is the headline WAND case (most blocks skippable).
        for k in [1, 5, 20, 50, 100] {
            let wand = try wandTopK(db, "rank", "alpha", k: k)
            let full = try Array(scoreAllOrder(db, "rank", "alpha").prefix(k))
            #expect(wand == full, "alpha top-\(k): WAND \(wand) vs score-all \(full)")
            #expect(wand.count == k, "alpha top-\(k) should fill k (corpus ≥ k)")
        }
    }

    @Test func wandMatchesScoreAllWeighted() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandw.adsql"))
        defer { db.close() }
        try build(db)

        // Heavy title weighting reorders relative to body hits — the bound must stay
        // admissible under the larger maxWeight, so WAND must still match score-all.
        for expr in ["bm25(fts, 10.0, 1.0)", "bm25(fts, 1.0, 5.0)", "bm25(fts)"] {
            for k in [10, 30] {
                let wand = try wandTopK(db, expr, "alpha", k: k)
                let full = try Array(scoreAllOrder(db, expr, "alpha").prefix(k))
                #expect(wand == full, "\(expr) top-\(k): WAND \(wand) vs score-all \(full)")
            }
        }
    }

    @Test func wandMatchesScoreAllOR() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandor.adsql"))
        defer { db.close() }
        try build(db)

        for query in ["alpha OR rare", "beta OR gamma", "alpha OR beta OR gamma"] {
            for k in [5, 20, 60] {
                let wand = try wandTopK(db, "rank", query, k: k)
                let full = try Array(scoreAllOrder(db, "rank", query).prefix(k))
                #expect(wand == full, "OR '\(query)' top-\(k): WAND \(wand) vs score-all \(full)")
            }
        }
    }

    @Test func wandMatchesScoreAllAND() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandand.adsql"))
        defer { db.close() }
        try build(db)

        for query in ["alpha AND beta", "alpha AND gamma", "alpha AND beta AND gamma"] {
            for k in [3, 10, 40] {
                let wand = try wandTopK(db, "rank", query, k: k)
                let full = try Array(scoreAllOrder(db, "rank", query).prefix(k))
                #expect(wand == full, "AND '\(query)' top-\(k): WAND \(wand) vs score-all \(full)")
            }
        }
    }

    // MARK: - Edge cases

    /// k larger than the match count: WAND returns ALL matches, still in score-all
    /// order (the heap never fills, so nothing is pruned).
    @Test func limitExceedingMatchCount() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandbig.adsql"))
        defer { db.close() }
        try build(db, count: 60)

        let full = try scoreAllOrder(db, "rank", "rare")  // sparse: few matches
        let wand = try wandTopK(db, "rank", "rare", k: 1000)
        #expect(wand == full, "k ≫ matches: WAND \(wand) vs score-all \(full)")
        #expect(wand.count == full.count && wand.count < 60)
    }

    /// AND where one operand is absent from the corpus ⇒ empty intersection (the
    /// missing-term early-out), identical to score-all.
    @Test func andWithMissingTermIsEmpty() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandmiss.adsql"))
        defer { db.close() }
        try build(db, count: 60)

        let wand = try wandTopK(db, "rank", "alpha AND zzznotpresent", k: 10)
        let full = try scoreAllOrder(db, "rank", "alpha AND zzznotpresent")
        #expect(wand.isEmpty && full.isEmpty)
    }

    /// A term absent from the corpus (single term) ⇒ empty, identical to score-all.
    @Test func absentSingleTermIsEmpty() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandabsent.adsql"))
        defer { db.close() }
        try build(db, count: 60)

        let wand = try wandTopK(db, "rank", "zzznotpresent", k: 10)
        #expect(wand.isEmpty)
    }

    // MARK: - Fallback shapes (WAND declines; score-all still correct)

    /// Prefix, phrase, NOT, and column-filtered queries fall back to score-all.
    /// They must still return the correct ranked top-k (equal to the full order),
    /// proving the fallback path is intact and the routing is safe.
    @Test func fallbackShapesStillRankCorrectly() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("wandfb.adsql"))
        defer { db.close() }
        try build(db)

        let cases = [
            "alph*",  // prefix expansion → fallback
            "\"alpha value\"",  // phrase → fallback
            "alpha NOT beta",  // NOT operand → fallback
            "title:alpha",  // column filter → fallback
            "alpha AND (beta OR gamma)",  // mixed AND/OR → fallback
        ]
        for query in cases {
            for k in [5, 25] {
                let wand = try wandTopK(db, "rank", query, k: k)
                let full = try Array(scoreAllOrder(db, "rank", query).prefix(k))
                #expect(wand == full, "fallback '\(query)' top-\(k): \(wand) vs \(full)")
            }
        }
    }

    // MARK: - Classifier (unit, no I/O)

    @Test func classifierAcceptsTermsAndAndOr() throws {
        // Single term, AND chain, OR chain ⇒ eligible.
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha")) != nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha beta")) != nil)  // implicit AND
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha AND beta AND gamma")) != nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha OR beta OR gamma")) != nil)
    }

    @Test func classifierRejectsHardShapes() throws {
        // Prefix, phrase-adjacency, NOT, column filter, and mixed AND/OR ⇒ fall back.
        #expect(FTSWAND.classify(try FTSQuery.parse("alph*")) == nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("\"alpha beta\"")) == nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha NOT beta")) == nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("title:alpha")) == nil)
        #expect(FTSWAND.classify(try FTSQuery.parse("alpha AND (beta OR gamma)")) == nil)
    }

    // MARK: - Admissible-bound math (unit)

    /// The per-block bound must never UNDERESTIMATE the true contribution of any doc
    /// in the block: for every weighted tf ≤ maxWeight·maxTotalTF and every doc
    /// length D ≥ dMin, `contribution(idf, wf, lengthNorm(D)) ≤ blockBound`.
    @Test func blockBoundIsAdmissible() throws {
        let idf = 2.3
        let maxWeight = 10.0
        let avgdl = 25.0
        let dMin = 1.0
        let maxTotalTF: UInt32 = 6
        let bound = FTSWAND.blockBound(
            idf: idf, maxTotalTF: maxTotalTF, maxWeight: maxWeight, avgdl: avgdl, dMin: dMin)

        // Sweep plausible (weightedFreq, D) pairs within the block's envelope.
        let wfMax = maxWeight * Double(maxTotalTF)
        for tfStep in 0...Int(maxTotalTF) {
            // Any weighted tf realizable in the block is ≤ wfMax.
            let wf = min(maxWeight * Double(tfStep), wfMax)
            guard wf > 0 else { continue }
            for d in stride(from: dMin, through: avgdl * 4, by: 3.0) {
                let ln = FTSScorer.lengthNorm(docLength: d, avgdl: avgdl)
                let real = FTSScorer.contribution(idf: idf, weightedFreq: wf, lengthNorm: ln)
                #expect(real <= bound + 1e-12, "bound \(bound) underestimated real \(real) (wf=\(wf), D=\(d))")
            }
        }
    }

    /// An empty block (no term occurrences, maxTotalTF == 0) or a zero max weight
    /// has a zero bound — it can contribute nothing.
    @Test func degenerateBoundsAreZero() {
        #expect(
            FTSWAND.blockBound(idf: 2.0, maxTotalTF: 0, maxWeight: 5.0, avgdl: 10.0, dMin: 1.0) == 0)
        #expect(
            FTSWAND.blockBound(idf: 2.0, maxTotalTF: 4, maxWeight: 0.0, avgdl: 10.0, dMin: 1.0) == 0)
    }
}
