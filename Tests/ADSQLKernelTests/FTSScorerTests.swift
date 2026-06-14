import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// M5 / F4a — the bm25f scorer (`FTSScorer`). Driven through `WriteTxn.ftsScore`
/// (parse + score over the F2 index). Scores are SQLite-signed: **negative, and
/// smaller is more relevant**, so a "better" score is more negative. These are
/// relevance/monotonicity properties (not byte-identity to FTS5 — the SQL
/// surface in `FTSRankTests` carries the differential ordering gate).
@Suite("FTS5 — F4a bm25f scorer")
struct FTSScorerTests {
    private func run(_ db: Database, _ sql: String) throws { try db.prepare(sql).run() }

    private func score(
        _ db: Database, _ table: String, _ query: String, docid: Int64, weights: [Double]? = nil
    ) throws -> Double {
        try db.writeSync { (txn) throws(DBError) in
            try txn.ftsScore(table, query, weights: weights, docid: docid)
        }
    }

    // MARK: - IDF monotonic in document frequency

    /// A term in fewer documents must score at least as well (more negative) as a
    /// term in more documents, holding tf and length equal. "rare" appears in one
    /// doc; "common" appears in all four — same single occurrence in doc 1.
    @Test func idfFallsAsDocumentFrequencyRises() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsidf.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='unicode61')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(1, 'rare common alpha beta')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(2, 'common gamma delta epsilon')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(3, 'common zeta eta theta')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(4, 'common iota kappa lambda')")

        let rareScore = try score(db, "fts", "rare", docid: 1)
        let commonScore = try score(db, "fts", "common", docid: 1)
        // df(rare)=1 < df(common)=4 → rare is strictly more informative (better).
        #expect(rareScore < commonScore)
        // "common" is in all 4 of 4 docs → raw IDF = log((4-4+0.5)/(4+0.5)) < 0,
        // clamped to 1e-6 (FTS5 behavior), so its score is a tiny negative near zero
        // — far weaker than the rare term, never inverting the ranking.
        #expect(commonScore < 0)
        #expect(commonScore > -0.001, "clamped-IDF score is near zero, got \(commonScore)")
        #expect(rareScore < -0.1, "rare term keeps a strong negative score, got \(rareScore)")
    }

    // MARK: - Score improves with term frequency

    /// More occurrences of the query term in a document → a better (more negative)
    /// score. Docs 1 and 2 have the same length (6 tokens); doc 1 mentions "swift"
    /// three times, doc 2 once. Filler docs 3–5 keep "swift" discriminating
    /// (df=2 of 5 → positive IDF), so higher tf is genuinely better.
    @Test func scoreImprovesWithTermFrequency() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftstf.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='unicode61')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(1, 'swift swift swift alpha beta gamma')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(2, 'swift alpha beta gamma delta epsilon')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(3, 'alpha beta gamma delta epsilon zeta')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(4, 'eta theta iota kappa lambda mu')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(5, 'nu xi omicron pi rho sigma')")

        let high = try score(db, "fts", "swift", docid: 1)
        let low = try score(db, "fts", "swift", docid: 2)
        #expect(high < low)  // more occurrences → more negative → better
        #expect(high < 0)  // discriminating term → genuinely negative (relevant)
    }

    // MARK: - Length normalization: longer docs score worse

    /// With the same term frequency, a longer document scores worse (b>0 length
    /// normalization). Docs 1 and 2 mention "swift" exactly once; doc 2 is padded.
    /// Filler docs 3–5 keep "swift" discriminating (df=2 of 5 → strictly positive
    /// IDF; df=2 of 4 would give log(1)=0 and erase every score).
    @Test func longerDocumentScoresWorse() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftslen.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='unicode61')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(1, 'swift alpha')")
        try run(
            db,
            "INSERT INTO fts(rowid, body) VALUES(2, "
                + "'swift alpha beta gamma delta epsilon zeta eta theta iota kappa lambda')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(3, 'mu nu xi omicron pi rho')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(4, 'sigma tau upsilon phi chi psi')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(5, 'aa bb cc dd ee ff')")

        let shortDoc = try score(db, "fts", "swift", docid: 1)
        let longDoc = try score(db, "fts", "swift", docid: 2)
        #expect(shortDoc < longDoc)  // shorter (denser) doc is better
        #expect(shortDoc < 0)
    }

    // MARK: - Field weights shift ranking (bm25f)

    /// Per-field weights change which document wins. Doc 1 has the term in its
    /// title; doc 2 has it in its body, each once, both same total length.
    /// Weighting the title field up makes the title match win; weighting the body
    /// up flips it.
    @Test func fieldWeightsShiftRanking() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsbm25f.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='unicode61')")
        // doc 1: target in title; doc 2: target in body. Same total token counts so
        // length normalization is identical and only the field weight differs.
        // Filler docs 3–5 keep "target" discriminating (df=2 of 5 → strictly
        // positive IDF; df=2 of 4 would give log(1)=0 and erase every score).
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(1, 'target one', 'two three')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(2, 'one two', 'target three')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(3, 'alpha beta', 'gamma delta')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(4, 'epsilon zeta', 'eta theta')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(5, 'iota kappa', 'lambda mu')")

        // Weight title heavily: the title-bearing doc 1 wins (more negative).
        let titleHeavy: [Double] = [10, 1]
        let doc1Title = try score(db, "fts", "target", docid: 1, weights: titleHeavy)
        let doc2Title = try score(db, "fts", "target", docid: 2, weights: titleHeavy)
        #expect(doc1Title < doc2Title)

        // Weight body heavily: the body-bearing doc 2 wins instead.
        let bodyHeavy: [Double] = [1, 10]
        let doc1Body = try score(db, "fts", "target", docid: 1, weights: bodyHeavy)
        let doc2Body = try score(db, "fts", "target", docid: 2, weights: bodyHeavy)
        #expect(doc2Body < doc1Body)
    }

    /// `rank` (all-ones weights) and an explicit all-ones `bm25()` are identical,
    /// and differ from a non-uniform weighting when the term sits in one field.
    @Test func uniformWeightsDifferFromWeighted() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsuniform.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='unicode61')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(1, 'target alpha', 'beta gamma')")
        // Filler so "target" is discriminating (df=1 of 3 → positive IDF), making a
        // higher title weight strengthen (more negative) the score.
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(2, 'delta epsilon', 'zeta eta')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(3, 'theta iota', 'kappa lambda')")

        let allOnes = try score(db, "fts", "target", docid: 1, weights: [1, 1])
        let defaulted = try score(db, "fts", "target", docid: 1)  // nil → all-ones
        #expect(allOnes == defaulted)
        // The term is title-only, so a higher title weight strengthens the score.
        let titleHeavy = try score(db, "fts", "target", docid: 1, weights: [5, 1])
        #expect(titleHeavy < allOnes)
    }

    // MARK: - Phrase scoring + NOT exclusion

    /// A phrase scores by its per-column adjacency count, and a `NOT` operand is a
    /// pure exclusion that never contributes to the score.
    @Test func phraseScoresAndNotIsExcludedFromScoring() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsphrase.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='unicode61')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(1, 'quick brown fox jumps high')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(2, 'brown quick slow lazy dog')")
        // Filler so the phrase "quick brown" (df=1, doc 1 only) is discriminating.
        try run(db, "INSERT INTO fts(rowid, body) VALUES(3, 'alpha beta gamma delta epsilon')")
        try run(db, "INSERT INTO fts(rowid, body) VALUES(4, 'zeta eta theta iota kappa')")

        // The phrase "quick brown" is adjacent only in doc 1 → it scores (negative).
        let phrase = try score(db, "fts", "\"quick brown\"", docid: 1)
        #expect(phrase < 0)

        // "quick" alone, vs "quick NOT lazy": the NOT side ("lazy") is an exclusion,
        // so the positive leaf is identical and the scores are equal.
        let plain = try score(db, "fts", "quick", docid: 1)
        let withExclusion = try score(db, "fts", "quick NOT lazy", docid: 1)
        #expect(plain == withExclusion)
    }
}
