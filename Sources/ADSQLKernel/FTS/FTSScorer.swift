import Darwin

/// bm25 / bm25f relevance scoring (M5/F4a). Turns an `FTSQuery` (F3a) plus the
/// F2 index statistics into a single relevance score per matching document,
/// using the Okapi BM25 ranking function with per-field weights (bm25f) —
/// SQLite FTS5's `rank` / `bm25()` model.
///
/// Only **positive query leaves** score: terms/phrases reached under `AND`/`OR`
/// (and inside a `col:` restriction) contribute; the right operand of a `NOT`
/// is a pure exclusion (already removed from the match set by F3b) and never
/// scores. For each positive leaf phrase `p`:
///
///   - `IDF(p) = log((N − df_p + 0.5) / (df_p + 0.5))` — SQLite's form (it may
///     go negative for a term in more than half the corpus, matching FTS5).
///   - `wf(p, row) = Σ_c weight_c · freq(p, c, row)` — weighted occurrences of
///     `p` in each column `c` (a term: per-column tf; a phrase: per-column
///     adjacency count). A `col:` restriction zeroes the weight of every other
///     column.
///   - `D = Σ_c fieldLengths(row)`; `avgdl = (Σ_c totalFieldLengths) / N`.
///   - `contribution = IDF(p) · wf·(k1+1) / (wf + k1·(1 − b + b·D/avgdl))`.
///
/// `score(row) = −Σ_p contribution`. The sum is **negated** so that, per the
/// SQLite convention, smaller (more negative) is more relevant and `ORDER BY
/// rank` / `ORDER BY bm25(…)` lists the best matches first.
enum FTSScorer {
  /// BM25 term-frequency saturation parameter (SQLite FTS5 default).
  static let k1 = 1.2
  /// BM25 length-normalization parameter (SQLite FTS5 default).
  static let b = 0.75

  /// The (negated) bm25f score of `docid` for `query`. `weights` is per-column
  /// (length == the FTS table's column count; the caller pads with 1.0). `global`
  /// is the corpus aggregate, fetched once by the caller and reused per docid.
  static func score(
    _ query: FTSQuery, record: Catalog.FTSRecord, resolver: some PageResolver,
    docid: Int64, weights: [Double], global: FTSGlobalStats
  ) throws(DBError) -> Double {
    let columns = record.definition.columns.count
    guard global.docCount > 0 else { return 0 }
    guard let docStats = try FTSIndex.docStats(resolver, record, docid: docid) else { return 0 }

    // D = the document's total length across all columns; avgdl = the corpus
    // average of that total. Guard a zero avgdl (degenerate empty corpus).
    let docLength = docStats.fieldLengths.reduce(0.0) { $0 + Double($1) }
    let totalLength = global.totalFieldLengths.reduce(0.0) { $0 + Double($1) }
    let avgdl = totalLength / Double(global.docCount)
    guard avgdl > 0 else { return 0 }
    let lengthNorm = k1 * (1 - b + b * docLength / avgdl)

    let scorer = try Scorer(record: record, resolver: resolver, columns: columns)
    var total = 0.0
    // `allowed == nil` means every column may contribute weight; a `col:` filter
    // narrows it. The intersection mirrors F3b's column restriction.
    try scorer.collectLeaves(query, columns: nil) { leaf, allowed throws(DBError) in
      let df = try scorer.documentFrequency(leaf)
      let n = Double(global.docCount)
      let idf = log((n - Double(df) + 0.5) / (Double(df) + 0.5))
      var weightedFreq = 0.0
      let perColumn = try scorer.frequencies(leaf, docid: docid)
      for column in 0..<columns where allowed?.contains(column) ?? true {
        weightedFreq += weights[column] * Double(perColumn[column])
      }
      guard weightedFreq > 0 else { return }
      total += idf * weightedFreq * (k1 + 1) / (weightedFreq + lengthNorm)
    }
    return -total
  }

  /// Walks the query collecting positive leaf phrases with the set of columns
  /// each may score in. Owns a tokenizer so a leaf's text resolves to the same
  /// stems the index stored (mirrors `FTSMatch.Matcher`).
  private struct Scorer<R: PageResolver> {
    let record: Catalog.FTSRecord
    let resolver: R
    let columns: Int
    let tokenizer: any FTSTokenizer

    init(record: Catalog.FTSRecord, resolver: R, columns: Int) throws(DBError) {
      self.record = record
      self.resolver = resolver
      self.columns = columns
      self.tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)
    }

    /// Invokes `visit(leaf, allowedColumns)` for every positive leaf phrase.
    /// `NOT` right operands are skipped; `col:` restrictions intersect into the
    /// allowed-column set passed down. A nil set means "all columns".
    func collectLeaves(
      _ query: FTSQuery, columns allowed: Set<Int>?,
      _ visit: (FTSQuery, Set<Int>?) throws(DBError) -> Void
    ) throws(DBError) {
      switch query {
      case .phrase:
        try visit(query, allowed)
      case .and(let lhs, let rhs), .or(let lhs, let rhs):
        try collectLeaves(lhs, columns: allowed, visit)
        try collectLeaves(rhs, columns: allowed, visit)
      case .not(let lhs, _):
        // The excluded side never scores; only the positive operand does.
        try collectLeaves(lhs, columns: allowed, visit)
      case .column(let names, let inner):
        try collectLeaves(inner, columns: try restrict(allowed, to: names), visit)
      }
    }

    private func restrict(_ current: Set<Int>?, to names: [String]) throws(DBError) -> Set<Int> {
      var resolved = Set<Int>()
      for name in names {
        guard let index = record.definition.columns.firstIndex(of: name) else {
          throw DBError.sqlRuntime("no such column \(name) in FTS table \(record.definition.name)")
        }
        resolved.insert(index)
      }
      return current.map { $0.intersection(resolved) } ?? resolved
    }

    /// Document frequency of a leaf phrase: a single term reads the dict df
    /// directly; a multi-term phrase counts the documents whose postings hold the
    /// phrase as an adjacency (so IDF reflects the phrase, not its rarest term).
    func documentFrequency(_ leaf: FTSQuery) throws(DBError) -> UInt64 {
      guard case .phrase(let text, let prefix) = leaf else { return 0 }
      let tokens = try tokenizer.allTokens(Array(text.utf8)).map(\.term)
      if tokens.isEmpty { return 0 }
      if tokens.count == 1 {
        return try termDocumentFrequency(tokens[0], prefix: prefix)
      }
      // Phrase df: documents where the tokens occur adjacently (any column).
      return UInt64(try phraseDocs(tokens, prefix: prefix).count)
    }

    /// df of a single term; a trailing `*` sums the postings across the prefix
    /// expansion's distinct documents (union, not double-counting a doc).
    private func termDocumentFrequency(_ term: [UInt8], prefix: Bool) throws(DBError) -> UInt64 {
      if !prefix { return try FTSIndex.documentFrequency(resolver, record, term: term) }
      var docs = Set<Int64>()
      for expansion in try FTSIndex.termsMatchingPrefix(resolver, record, prefix: term) {
        if let postings = try FTSIndex.postings(resolver, record, term: expansion) {
          for posting in postings { docs.insert(posting.docid) }
        }
      }
      return UInt64(docs.count)
    }

    /// Per-column frequency of a leaf phrase in `docid`: the per-field tf for a
    /// term, or the per-field adjacency count for a multi-term phrase.
    func frequencies(_ leaf: FTSQuery, docid: Int64) throws(DBError) -> [UInt32] {
      guard case .phrase(let text, let prefix) = leaf else {
        return [UInt32](repeating: 0, count: columns)
      }
      let tokens = try tokenizer.allTokens(Array(text.utf8)).map(\.term)
      if tokens.isEmpty { return [UInt32](repeating: 0, count: columns) }
      if tokens.count == 1 {
        return try termFrequencies(tokens[0], prefix: prefix, docid: docid)
      }
      return try phraseFrequencies(tokens, prefix: prefix, docid: docid)
    }

    /// Per-column tf of a term in `docid`; a trailing `*` sums the per-column tf
    /// over the prefix expansion (each expanded term is a distinct occurrence).
    private func termFrequencies(
      _ term: [UInt8], prefix: Bool, docid: Int64
    ) throws(DBError) -> [UInt32] {
      var freqs = [UInt32](repeating: 0, count: columns)
      let terms = prefix
        ? try FTSIndex.termsMatchingPrefix(resolver, record, prefix: term) : [term]
      for expansion in terms {
        guard let postings = try FTSIndex.postings(resolver, record, term: expansion) else { continue }
        guard let posting = postings.first(where: { $0.docid == docid }) else { continue }
        for column in 0..<min(columns, posting.fieldTFs.count) {
          freqs[column] &+= posting.fieldTFs[column]
        }
      }
      return freqs
    }

    /// Per-column adjacency count of a multi-term phrase in `docid`. A position
    /// in column `c` counts when the tokens appear at consecutive positions
    /// (`pos[t] + 1 == pos[t+1]`), the same adjacency F3b tests for membership.
    private func phraseFrequencies(
      _ tokens: [[UInt8]], prefix: Bool, docid: Int64
    ) throws(DBError) -> [UInt32] {
      guard record.definition.detail != .none else {
        // Without positions the phrase cannot be scored per column; it still
        // matched (F3b requires positions for phrases), so contribute nothing.
        return [UInt32](repeating: 0, count: columns)
      }
      var freqs = [UInt32](repeating: 0, count: columns)
      for expanded in try expand(tokens, prefix: prefix) {
        let perColumn = try adjacencyCounts(expanded, docid: docid)
        for column in 0..<columns { freqs[column] &+= perColumn[column] }
      }
      return freqs
    }

    /// Documents where the phrase occurs adjacently in any column.
    private func phraseDocs(_ tokens: [[UInt8]], prefix: Bool) throws(DBError) -> Set<Int64> {
      guard record.definition.detail != .none else { return [] }
      var docs = Set<Int64>()
      for expanded in try expand(tokens, prefix: prefix) {
        let byToken = try postingsByDoc(expanded)
        guard let first = byToken.first else { continue }
        var candidates = Set(first.keys)
        for map in byToken.dropFirst() { candidates.formIntersection(map.keys) }
        for docid in candidates where adjacencyCounts(byToken, docid: docid).contains(where: { $0 > 0 }) {
          docs.insert(docid)
        }
      }
      return docs
    }

    /// Trailing `*` expands the last token over its prefix terms, yielding one
    /// concrete token sequence per expansion; no `*` yields the tokens as-is.
    private func expand(_ tokens: [[UInt8]], prefix: Bool) throws(DBError) -> [[[UInt8]]] {
      guard prefix else { return [tokens] }
      var sequences: [[[UInt8]]] = []
      let last = tokens[tokens.count - 1]
      for expansion in try FTSIndex.termsMatchingPrefix(resolver, record, prefix: last) {
        var expanded = tokens
        expanded[expanded.count - 1] = expansion
        sequences.append(expanded)
      }
      return sequences
    }

    private func postingsByDoc(_ tokens: [[UInt8]]) throws(DBError) -> [[Int64: FTSPosting]] {
      var byToken: [[Int64: FTSPosting]] = []
      for token in tokens {
        guard let postings = try FTSIndex.postings(resolver, record, term: token) else { return [] }
        var map: [Int64: FTSPosting] = [:]
        for posting in postings { map[posting.docid] = posting }
        byToken.append(map)
      }
      return byToken
    }

    private func adjacencyCounts(_ tokens: [[UInt8]], docid: Int64) throws(DBError) -> [UInt32] {
      adjacencyCounts(try postingsByDoc(tokens), docid: docid)
    }

    /// Per-column count of consecutive-position phrase hits for `docid`: for each
    /// starting position of the first token in a column, the phrase counts once
    /// when every later token sits at the next position.
    private func adjacencyCounts(_ byToken: [[Int64: FTSPosting]], docid: Int64) -> [UInt32] {
      var freqs = [UInt32](repeating: 0, count: columns)
      guard let firstPositions = byToken.first?[docid]?.positions else { return freqs }
      for column in 0..<columns where column < firstPositions.count {
        let starts = firstPositions[column]
        if starts.isEmpty { continue }
        var followers: [Set<UInt32>] = []
        var usable = true
        for index in 1..<byToken.count {
          guard let positions = byToken[index][docid]?.positions, column < positions.count else {
            usable = false
            break
          }
          followers.append(Set(positions[column]))
        }
        guard usable else { continue }
        for start in starts {
          var matched = true
          for (offset, set) in followers.enumerated() where !set.contains(start + UInt32(offset + 1)) {
            matched = false
            break
          }
          if matched { freqs[column] &+= 1 }
        }
      }
      return freqs
    }
  }
}
