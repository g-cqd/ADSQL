/// The block-max WAND top-k driver (F6c). Given the WAND-eligible single-term
/// leaves of a ranked query (from `FTSWAND.classify`), it retrieves the top-k
/// `(docid, score)` the score-all path would have produced — using a size-k
/// min-heap and the per-block admissible bounds (`FTSWANDCursor`) to skip blocks
/// and documents that cannot enter the heap, and scoring survivors directly from
/// the block-max cursor's per-document field-TFs (avoiding the score-all path's
/// per-document full-posting-list re-decode).
///
/// ## Identical-result contract
///   - A surviving document's score is computed with the SAME `FTSScorer`
///     primitives the score-all path uses (`idf` / `lengthNorm` / `contribution`),
///     from the SAME on-disk field-TF bytes and the SAME per-doc length, summed in
///     the SAME leaf order (left-to-right, present terms only) — so it is
///     bit-identical to `FTSScorer.score`. The block bound is only a skip test,
///     never the reported score.
///   - Documents are visited in ascending docid order, and the heap keeps the k
///     LARGEST relevances, breaking ties toward the SMALLEST docid (an equal-
///     scored later/larger docid never displaces an earlier/smaller one). This is
///     exactly how the executor's bounded top-N resolves `ORDER BY rank[, rowid]`
///     ties (stable, scan-order, drop-last), and the result is returned already in
///     final ranked order, so the accumulator reproduces the identical projection.
///   - The pruning threshold is the heap's current k-th best relevance `θ`; a
///     block or document is skipped only when its admissible bound is `< θ`
///     (strict). A bound `== θ` is not skipped: its true relevance could equal
///     `θ`, and the tie-aware heap (not the prune) decides whether it enters.
///
/// Returns nil when WAND cannot run (degenerate stats / a term that does not
/// resolve to a single stem); the caller then uses the score-all path. An empty
/// (non-nil) result means the query genuinely matched nothing.
enum FTSWANDTopK {
  /// Runs WAND for the top-`k` of `eligible` against `record`. `weights` are the
  /// per-column bm25 weights (already padded to the FTS column count). `global` is
  /// the corpus aggregate (fetched once). Returns the top-k in final ranked order
  /// (most relevant first; ties by docid ascending), or nil to fall back.
  static func run<R: PageResolver>(
    eligible: FTSWAND.Eligible, query: FTSQuery, record: Catalog.FTSRecord, resolver: R,
    weights: [Double], global: FTSGlobalStats, k: Int
  ) throws(DBError) -> [(docid: Int64, score: Double)]? {
    guard k >= 1, global.docCount > 0 else { return nil }
    let columns = record.definition.columns.count
    let storePositions = record.definition.detail != .none
    let totalLength = global.totalFieldLengths.reduce(0.0) { $0 + Double($1) }
    let avgdl = totalLength / Double(global.docCount)
    guard avgdl > 0 else { return nil }
    // Largest per-column weight bounds the weighted tf (see `FTSWAND.blockBound`).
    let maxWeight = weights.prefix(columns).max() ?? 0
    guard maxWeight > 0 else { return nil }
    // Dmin = 1: any matched document holds the term, so D ≥ 1 token. A lower
    // bound on D (smaller D ⇒ larger score) keeps the block bound admissible.
    let dMin = 1.0

    // Resolve each query term to a block-max cursor, in the query's leaf order
    // (so the score-sum order matches `FTSScorer`'s traversal). A term that does
    // not tokenize to exactly one stem makes WAND inapplicable — fall back. A term
    // absent from the index contributes no postings: for OR it is dropped (its
    // contribution would be 0, which the scorer skips anyway); for AND its absence
    // empties the intersection.
    let tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)
    var cursors: [FTSWANDCursor] = []
    cursors.reserveCapacity(eligible.terms.count)
    for term in eligible.terms {
      let stems = try tokenizer.allTokens(Array(term.utf8)).map(\.term)
      guard stems.count == 1, !stems[0].isEmpty else { return nil }
      let stem = stems[0]
      let df = try FTSIndex.documentFrequency(resolver, record, term: stem)
      guard df > 0, let bytes = try rawPostings(resolver, record, term: stem) else {
        if eligible.op == .and { return [] }  // AND with a missing term ⇒ empty.
        continue
      }
      guard
        let cursor = FTSWANDCursor(
          bytes: bytes, df: df, docCount: global.docCount, columns: columns,
          storePositions: storePositions, maxWeight: maxWeight, avgdl: avgdl, dMin: dMin)
      else {
        if eligible.op == .and { return [] }
        continue
      }
      cursors.append(cursor)
    }
    guard !cursors.isEmpty else { return [] }

    // The shared scorer: turns a document + its contributing cursors into the
    // bit-identical positive relevance `S = Σ contribution`.
    let scorer = DocScorer(
      record: record, resolver: resolver, weights: weights, columns: columns, avgdl: avgdl)

    var heap = TopKHeap(capacity: k)
    if cursors.count == 1 {
      // Single term (the hot case, e.g. "view"): pure block-max skipping — drop a
      // whole block whose bound cannot beat θ without decoding or scoring it.
      try runSingleTerm(&cursors[0], heap: &heap, scorer: scorer)
    } else {
      switch eligible.op {
      case .or:
        try runDisjunctive(&cursors, heap: &heap, scorer: scorer)
      case .and:
        try runConjunctive(&cursors, heap: &heap, scorer: scorer)
      }
    }
    // Convert the kept entries to the `FTSScorer` convention (negated `S`) and
    // return them in final ranked order: ascending negated score (most relevant
    // first), ties by docid ascending — exactly the order the score-all path feeds
    // the bounded top-N (docid-ascending scan + stable sort), so the accumulator
    // reproduces the identical projected order with or without an explicit `,
    // rowid` tiebreak.
    var entries = heap.drain().map { (docid: $0.docid, score: -$0.score) }
    entries.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score < rhs.score }
      return lhs.docid < rhs.docid
    }
    return entries
  }

  // MARK: - Single term (pure block-max skipping)

  /// One posting list: walk it block by block; skip an ENTIRE block whose
  /// admissible bound is `< θ` (no doc in it can enter the heap), otherwise score
  /// each of its documents directly from the cursor. This is where block-max
  /// pruning pays the most — the late blocks of a near-universal term that all
  /// fall under the rising threshold are jumped over wholesale.
  private static func runSingleTerm<R: PageResolver>(
    _ cursor: inout FTSWANDCursor, heap: inout TopKHeap, scorer: DocScorer<R>
  ) throws(DBError) {
    while let docid = cursor.current {
      let bound = cursor.currentBlockBound ?? 0
      if heap.isFull, bound < heap.threshold {
        if let last = cursor.currentBlockLast {
          cursor.advance(to: last + 1)
        } else {
          cursor.advancePast()
        }
        continue
      }
      let s = try scorer.score(docid: docid, contributors: [(cursor.idf, cursor.currentFieldTFs())])
      heap.offer(docid: docid, score: s)
      cursor.advancePast()
    }
  }

  // MARK: - Disjunctive (OR) block-max WAND

  /// Block-max WAND over a union: visit candidate docids ascending; a document's
  /// admissible bound is the sum of `currentBlockBound` over the cursors whose
  /// current posting is exactly that docid (only those terms occur in it). Skip a
  /// document whose bound `< θ`; otherwise score it for real from those cursors'
  /// field-TFs. The cursor's galloping `advance(to:)` block-max-skips toward the
  /// next live candidate for free.
  private static func runDisjunctive<R: PageResolver>(
    _ cursors: inout [FTSWANDCursor], heap: inout TopKHeap, scorer: DocScorer<R>
  ) throws(DBError) {
    while true {
      var pivot: Int64 = .max
      var anyLive = false
      for cursor in cursors {
        if let current = cursor.current {
          anyLive = true
          if current < pivot { pivot = current }
        }
      }
      guard anyLive else { break }

      var bound = 0.0
      for cursor in cursors where cursor.current == pivot {
        bound += cursor.currentBlockBound ?? 0
      }
      if heap.isFull, bound < heap.threshold {
        for index in cursors.indices where cursors[index].current == pivot {
          cursors[index].advancePast()
        }
        continue
      }
      // Gather contributors (terms present in `pivot`) in cursor-array order =
      // query leaf order, so the score sum matches `FTSScorer` exactly.
      var contributors: [(idf: Double, fieldTFs: [UInt32])] = []
      for index in cursors.indices where cursors[index].current == pivot {
        contributors.append((cursors[index].idf, cursors[index].currentFieldTFs()))
      }
      heap.offer(docid: pivot, score: try scorer.score(docid: pivot, contributors: contributors))
      for index in cursors.indices where cursors[index].current == pivot {
        cursors[index].advancePast()
      }
    }
  }

  // MARK: - Conjunctive (AND) block-max WAND

  /// Block-max WAND over an intersection: a document qualifies only when EVERY
  /// cursor is aligned on it. Advance lagging cursors to the current maximum docid
  /// (galloping skips non-intersecting docids); once aligned, prune by the summed
  /// block bound (skip when `< θ`) else score for real from every cursor's
  /// field-TFs.
  private static func runConjunctive<R: PageResolver>(
    _ cursors: inout [FTSWANDCursor], heap: inout TopKHeap, scorer: DocScorer<R>
  ) throws(DBError) {
    while true {
      var target: Int64 = .min
      for cursor in cursors {
        guard let current = cursor.current else { return }  // a list ran out ⇒ done.
        target = max(target, current)
      }
      var aligned = true
      for index in cursors.indices {
        cursors[index].advance(to: target)
        guard let current = cursors[index].current else { return }
        if current != target { aligned = false }
      }
      guard aligned else { continue }

      var bound = 0.0
      for cursor in cursors { bound += cursor.currentBlockBound ?? 0 }
      if !(heap.isFull && bound < heap.threshold) {
        var contributors: [(idf: Double, fieldTFs: [UInt32])] = []
        for index in cursors.indices {
          contributors.append((cursors[index].idf, cursors[index].currentFieldTFs()))
        }
        heap.offer(docid: target, score: try scorer.score(docid: target, contributors: contributors))
      }
      for index in cursors.indices { cursors[index].advancePast() }
    }
  }

  // MARK: - Postings raw bytes

  /// The raw encoded posting-list value for `term` (no decode), or nil if absent.
  private static func rawPostings(
    _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
  ) throws(DBError) -> [UInt8]? {
    // F6d: a term's postings live across block-keys; union them into the single
    // multi-block value the WAND cursor parses.
    try FTSIndex.postingsValue(resolver, record, term: term)
  }
}

/// Computes a document's positive bm25f relevance `S = Σ contribution` from its
/// contributing terms' per-column field-TFs, using the EXACT `FTSScorer`
/// primitives and operation order — so `−S` equals `FTSScorer.score` bit for bit.
/// The per-document length comes from the same `FTSIndex.docStats` the score-all
/// path reads; only the per-term posting re-decode is avoided (the cursor already
/// holds the field-TFs).
struct DocScorer<R: PageResolver> {
  let record: Catalog.FTSRecord
  let resolver: R
  let weights: [Double]
  let columns: Int
  let avgdl: Double

  /// `S` for `docid` given each contributing term's `(idf, fieldTFs)` in query
  /// leaf order. Mirrors `FTSScorer.score`: sum, per present leaf,
  /// `contribution(idf, Σ_c weight_c·tf_c, lengthNorm(D))`, skipping a leaf whose
  /// weighted frequency is 0. Returns 0 when the doc has no stats (degenerate;
  /// matches `FTSScorer`).
  func score(docid: Int64, contributors: [(idf: Double, fieldTFs: [UInt32])]) throws(DBError) -> Double {
    guard let docLength = try FTSIndex.docLength(resolver, record, docid: docid) else { return 0 }
    let lengthNorm = FTSScorer.lengthNorm(docLength: docLength, avgdl: avgdl)
    var total = 0.0
    for contributor in contributors {
      var weightedFreq = 0.0
      let tfs = contributor.fieldTFs
      for column in 0..<columns {
        let tf = column < tfs.count ? Double(tfs[column]) : 0
        weightedFreq += weights[column] * tf
      }
      guard weightedFreq > 0 else { continue }
      total += FTSScorer.contribution(
        idf: contributor.idf, weightedFreq: weightedFreq, lengthNorm: lengthNorm)
    }
    return total
  }
}

/// A bounded size-`k` max-by-relevance top-k collector. It keeps the k entries
/// with the LARGEST relevance; on a tie the SMALLER docid is preferred (an equal-
/// scored larger docid is rejected once full), matching the executor's stable
/// scan-order top-N tiebreak. `threshold` is the current k-th best relevance (the
/// bar a new entry must clear); `-infinity` until full so everything is admitted
/// while the heap fills.
///
/// Implemented as a binary MIN-heap keyed by `(relevance asc, docid desc)` so the
/// root is the worst kept entry — O(log k) to test and replace.
struct TopKHeap {
  /// (score, docid), heap-ordered so element 0 is the worst (smallest relevance;
  /// on ties, largest docid). `score` here is the POSITIVE relevance `S`.
  private var items: [(score: Double, docid: Int64)] = []
  private let capacity: Int

  init(capacity: Int) {
    self.capacity = capacity
    items.reserveCapacity(capacity)
  }

  var isFull: Bool { items.count >= capacity }

  /// The current admission bar: the worst kept relevance once full, else -infinity.
  var threshold: Double { isFull ? items[0].score : -.infinity }

  /// True when `a` is a WORSE entry than `b` (closer to the min-root): a smaller
  /// relevance is worse; on equal relevance a LARGER docid is worse (evicted
  /// first, leaving the smaller docid — the tie winner — in the heap).
  private func worse(_ a: (score: Double, docid: Int64), _ b: (score: Double, docid: Int64)) -> Bool {
    if a.score != b.score { return a.score < b.score }
    return a.docid > b.docid
  }

  /// Offers `(docid, score)`. Inserts while filling; once full, replaces the worst
  /// entry only if the candidate is strictly better than it.
  mutating func offer(docid: Int64, score: Double) {
    let candidate = (score: score, docid: docid)
    if items.count < capacity {
      items.append(candidate)
      siftUp(items.count - 1)
      return
    }
    if worse(items[0], candidate) {
      items[0] = candidate
      siftDown(0)
    }
  }

  /// The kept entries as `(docid, score)` (unordered; the caller sorts).
  func drain() -> [(docid: Int64, score: Double)] {
    items.map { (docid: $0.docid, score: $0.score) }
  }

  private mutating func siftUp(_ start: Int) {
    var child = start
    while child > 0 {
      let parent = (child - 1) / 2
      if worse(items[child], items[parent]) {
        items.swapAt(child, parent)
        child = parent
      } else {
        break
      }
    }
  }

  private mutating func siftDown(_ start: Int) {
    var parent = start
    let count = items.count
    while true {
      let left = parent * 2 + 1
      let right = left + 1
      var smallest = parent
      if left < count, worse(items[left], items[smallest]) { smallest = left }
      if right < count, worse(items[right], items[smallest]) { smallest = right }
      if smallest == parent { break }
      items.swapAt(parent, smallest)
      parent = smallest
    }
  }
}
