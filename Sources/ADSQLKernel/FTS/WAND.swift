/// Block-max WAND ranked top-k (M5/F6c — Ding & Suel, 2011). A *dynamic-pruning*
/// retrieval path for `ORDER BY bm25(…) LIMIT k` over an FTS5 table: instead of
/// scoring the entire MATCH candidate set and then sorting (the F4 score-all
/// path), it keeps a size-`k` heap and uses per-block score upper bounds — the
/// `maxTotalTF` carried in each posting block header (F2a) — to SKIP whole
/// blocks and documents that provably cannot enter the top-k.
///
/// ## Why it is a pure optimization (identical top-k)
/// The block bound is used ONLY to decide *whether* to score a document; a
/// document that survives pruning is scored by the EXACT same `FTSScorer.score`
/// the score-all path uses, so the surviving scores are bit-identical. WAND only
/// changes *which* documents are scored, never *how*. Provided the bound never
/// underestimates a real score (admissibility, below), the set of documents that
/// can enter the heap is a superset of the true top-k, so the heap converges on
/// the identical top-k — same rowids, same order — as score-all (and therefore,
/// transitively via the F6a parity gate, as SQLite FTS5).
///
/// ## The admissible per-block upper bound (never underestimates)
/// bm25f contribution of a positive term `t` to a document `d` is
///
///   contribution(t, d) = IDF(t) · wf·(k1+1) / (wf + k1·(1 − b + b·D/avgdl))
///
/// with `wf = Σ_c weight_c · tf_c(t, d)` (weighted term frequency) and
/// `D = Σ_c fieldLength_c(d)` (document total length). Treat it as
/// `f(wf, D) = IDF · wf·(k1+1) / (wf + L)`, `L = k1·(1 − b + b·D/avgdl)`:
///
///   - `∂f/∂wf = IDF·(k1+1)·L / (wf + L)² ≥ 0` — *increasing* in `wf`.
///   - `∂f/∂D  = −IDF·wf·(k1+1)·(k1·b/avgdl) / (wf + L)² ≤ 0` — *decreasing* in `D`.
///
/// So the contribution is maximized by the LARGEST plausible `wf` and the
/// SMALLEST plausible `D`. For a posting block we bound each:
///
///   - `wf ≤ maxWeight · maxTotalTF`, where `maxTotalTF` (block header) is the
///     max UNWEIGHTED Σ_c tf_c over the block's docs and `maxWeight = max_c
///     weight_c ≥ 0`. Since every `tf_c ≥ 0` and weights are non-negative,
///     `wf = Σ_c weight_c·tf_c ≤ maxWeight·Σ_c tf_c ≤ maxWeight·maxTotalTF`.
///   - `D ≥ Dmin = 1`: any document in a term's posting list contains the term,
///     so its total length is ≥ 1 token. Smaller `D` ⇒ larger contribution, so a
///     LOWER bound on `D` yields the upper bound on the score; `Dmin = 1` is the
///     safest provable lower bound (a conservative constant, per the F6c brief —
///     zero precompute, never larger than any real `D`).
///
/// Substituting gives `blockMax(t, block) = f(maxWeight·maxTotalTF, Dmin)` — a
/// quantity ≥ contribution(t, d) for every `d` in the block. The bound for a
/// *document* across the query's positive terms is the sum of the per-term block
/// maxes of the blocks currently covering that document, which is ≥ the document's
/// true Σ contribution. (A clamped `IDF ≤ 0` floor of `minIDF`, mirroring
/// `FTSScorer`, keeps the bound non-negative and consistent.)
///
/// ## Scope (which shapes use WAND vs fall back)
/// WAND requires a tight, cheap admissible block bound. It is taken only when the
/// MATCH query's positive leaves are all **single, non-prefix terms** combined by
/// AND / OR (the common ranked shapes). Anything else — phrases, prefix `term*`,
/// a `NOT` operand, or a `col:` column filter — FALLS BACK to the score-all path
/// (`classify` returns nil), preserving correctness while WAND speeds the common
/// case. The fallback decision is made before any pruning, at query time.
enum FTSWAND {
  // MARK: - Eligibility

  /// How a WAND-eligible query's single-term leaves combine.
  enum Combination { case and, or }

  /// The positive single-term leaves of a WAND-eligible query and their
  /// combination, or nil if the query falls back (a phrase, prefix, NOT operand,
  /// or column filter appears). Terms are the raw query words; the caller
  /// tokenizes them with the table tokenizer exactly as the scorer does.
  struct Eligible {
    var terms: [String]
    var op: Combination
  }

  static func classify(_ query: FTSQuery) -> Eligible? {
    switch query {
    case .phrase(let text, let prefix):
      // A prefix leaf (`term*`) expands to many dictionary terms with a
      // union-derived IDF (no tight single-block bound); a multi-word phrase
      // (`"a b"`) needs positions/adjacency, not an AND of its words. Both fall
      // back. A multi-word phrase carries internal whitespace; reject it upfront
      // (the runtime also rejects any term that does not tokenize to one stem).
      if prefix || text.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
        return nil
      }
      return Eligible(terms: [text], op: .or)
    case .and(let lhs, let rhs):
      return merge(classify(lhs), classify(rhs), as: .and)
    case .or(let lhs, let rhs):
      return merge(classify(lhs), classify(rhs), as: .or)
    case .not, .column:
      // NOT operands never score (exclusion); column filters narrow the weight
      // set per leaf. Both complicate the block bound — fall back.
      return nil
    }
  }

  /// Combines two eligible sub-results under `op`, requiring both sides eligible
  /// and the SAME combination throughout (no AND/OR mixing — kept simple and
  /// provably correct; a mixed tree falls back).
  private static func merge(_ lhs: Eligible?, _ rhs: Eligible?, as op: Combination) -> Eligible? {
    guard let lhs, let rhs else { return nil }
    if lhs.terms.count > 1, lhs.op != op { return nil }
    if rhs.terms.count > 1, rhs.op != op { return nil }
    return Eligible(terms: lhs.terms + rhs.terms, op: op)
  }

  // MARK: - Entry point

  /// Attempts block-max WAND for the top-`k` of `query` against `record`,
  /// returning the top-k `(docid, score)` (unordered — the executor's bounded
  /// top-N re-applies the full ORDER BY) or **nil to fall back** to the score-all
  /// path. nil is returned whenever WAND is inapplicable (an ineligible query
  /// shape, degenerate stats, or a term that does not resolve to a single stem),
  /// so the caller always has a correct path. An empty non-nil array means the
  /// query legitimately matched nothing.
  ///
  /// `weights` must already be padded to the FTS column count; `global` is the
  /// corpus aggregate fetched once by the caller.
  static func topK<R: PageResolver>(
    query: FTSQuery, record: Catalog.FTSRecord, resolver: R,
    weights: [Double], global: FTSGlobalStats, k: Int
  ) throws(DBError) -> [(docid: Int64, score: Double)]? {
    guard k >= 1, let eligible = classify(query) else { return nil }
    return try FTSWANDTopK.run(
      eligible: eligible, query: query, record: record, resolver: resolver,
      weights: weights, global: global, k: k)
  }

  // MARK: - Bound math

  /// The admissible per-block score bound `f(maxWeight·maxTotalTF, dMin)` (see the
  /// type doc). 0 when the block holds no term occurrences (maxTotalTF == 0) or
  /// the weight is 0 — that block can never contribute.
  static func blockBound(
    idf: Double, maxTotalTF: UInt32, maxWeight: Double, avgdl: Double, dMin: Double
  ) -> Double {
    guard maxTotalTF > 0, maxWeight > 0, avgdl > 0 else { return 0 }
    let wfUB = maxWeight * Double(maxTotalTF)
    let lengthNorm = FTSScorer.k1 * (1 - FTSScorer.b + FTSScorer.b * dMin / avgdl)
    return idf * wfUB * (FTSScorer.k1 + 1) / (wfUB + lengthNorm)
  }
}
