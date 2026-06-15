#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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
///   - `IDF(p) = log((N − df_p + 0.5) / (df_p + 0.5))`, clamped to a tiny
///     positive `1e-6` when ≤ 0 (FTS5's behavior: a term in more than half the
///     corpus would otherwise get a negative IDF and *invert* the ranking; the
///     clamp keeps it weakly positive so denser docs still rank first).
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
    /// Floor for a non-positive IDF (FTS5 clamps `IDF ≤ 0` to this so a term in
    /// more than half the corpus stays weakly discriminating instead of inverting
    /// the ranking).
    static let minIDF = 1e-6

    // MARK: - Scoring primitives (shared by score-all and the F6c WAND path)

    /// bm25 length-normalization term `L = k1·(1 − b + b·D/avgdl)` for a document of
    /// total length `docLength` against corpus average `avgdl`. Factored out so the
    /// WAND path computes it with the IDENTICAL arithmetic as `score`.
    @inline(__always)
    static func lengthNorm(docLength: Double, avgdl: Double) -> Double {
        k1 * (1 - b + b * docLength / avgdl)
    }

    /// Okapi IDF for a leaf with document frequency `df` over a corpus of `n`
    /// documents, clamped to `minIDF` when ≤ 0 (FTS5 behavior). Identical formula to
    /// the inline computation `score` used before this was factored out.
    @inline(__always)
    static func idf(df: UInt64, n: Double) -> Double {
        let raw = log((n - Double(df) + 0.5) / (Double(df) + 0.5))
        return raw <= 0 ? minIDF : raw
    }

    /// A single positive leaf's bm25f contribution given its `idf`, weighted term
    /// frequency `weightedFreq` (`Σ_c weight_c·tf_c`), and the document's length
    /// norm `L`. This is the exact per-leaf term `score` accumulates; both the
    /// score-all path and WAND call it, so their scores are bit-identical.
    @inline(__always)
    static func contribution(idf: Double, weightedFreq: Double, lengthNorm: Double) -> Double {
        idf * weightedFreq * (k1 + 1) / (weightedFreq + lengthNorm)
    }

    /// The (negated) bm25f score of `docid` for `query`. `weights` is per-column
    /// (length == the FTS table's column count; the caller pads with 1.0). `global`
    /// is the corpus aggregate, fetched once by the caller and reused per docid.
    ///
    /// A single-document convenience over `PreparedScorer`: it builds the query-
    /// scoped scorer and scores the one document. The executor's score-all path
    /// builds a `PreparedScorer` ONCE per query and scores every candidate through
    /// it, so the per-query resolution (each leaf's df/idf and per-document
    /// frequencies) is hoisted out of the per-document loop — a ranked scan no
    /// longer re-decodes a term's posting list, nor re-enumerates a `foo*` prefix's
    /// document frequency, per matching document. The result is bit-identical.
    static func score(
        _ query: FTSQuery, record: Catalog.FTSRecord, resolver: some PageResolver,
        docid: Int64, weights: [Double], global: FTSGlobalStats
    ) throws(DBError) -> Double {
        let prepared = try PreparedScorer(
            query: query, record: record, resolver: resolver, weights: weights, global: global)
        var statsCursor = Cursor(resolver: resolver, tree: record.stats)
        return try prepared.score(docid: docid, statsCursor: &statsCursor)
    }

    // MARK: - Query-scoped scorer

    /// A bm25f scorer resolved for ONE query: it reads each positive leaf's corpus
    /// statistics (df → IDF) and the per-document term/phrase frequencies it needs
    /// ONCE at construction, then scores any matching document by table lookup.
    ///
    /// This replaces the previous per-document leaf resolution, which re-decoded a
    /// term's whole posting list — and, for a `foo*` prefix or a phrase leaf, re-
    /// enumerated its expansion and rebuilt its document-frequency set — for every
    /// candidate document (the score-all path's dominant cost). The resolution is
    /// identical work done once: same leaf traversal order, same df / IDF, same per-
    /// column frequencies, summed with the same `contribution` arithmetic, so a
    /// score is bit-for-bit what the per-document path produced.
    struct PreparedScorer<R: PageResolver> {
        private let record: Catalog.FTSRecord
        private let resolver: R
        private let columns: Int
        private let weights: [Double]
        private let avgdl: Double
        /// A degenerate corpus (no documents, or a zero average length) scores every
        /// document 0, mirroring the per-document path's top guards.
        private let degenerate: Bool
        private let leaves: [PreparedLeaf]

        /// One positive query leaf, resolved for the whole query.
        private struct PreparedLeaf {
            /// IDF(leaf) — the corpus-wide discriminating weight (docid-independent).
            let idf: Double
            /// `col:` restriction (nil == every column may contribute).
            let allowed: Set<Int>?
            /// docid → per-column frequency (a term's per-field tf, or a phrase's per-
            /// field adjacency count). A docid absent here contributes nothing — exactly
            /// the per-document path's zero-frequency skip.
            let perDocFreq: [Int64: [UInt32]]
        }

        init(
            query: FTSQuery, record: Catalog.FTSRecord, resolver: R, weights: [Double],
            global: FTSGlobalStats
        ) throws(DBError) {
            self.record = record
            self.resolver = resolver
            let columns = record.definition.columns.count
            self.columns = columns
            self.weights = weights
            let totalLength = global.totalFieldLengths.reduce(0.0) { $0 + Double($1) }
            let avgdl = global.docCount > 0 ? totalLength / Double(global.docCount) : 0
            self.avgdl = avgdl
            self.degenerate = global.docCount == 0 || avgdl <= 0

            // Resolve every positive leaf once, in the query's left-to-right traversal
            // order (so the per-document score sum matches the previous path exactly).
            let tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)
            let n = Double(global.docCount)
            var resolved: [PreparedLeaf] = []
            try Self.collectLeaves(query, columns: nil, record: record) {
                (leaf, allowed) throws(DBError) in
                resolved.append(
                    try Self.prepareLeaf(
                        leaf, allowed: allowed, record: record, resolver: resolver, columns: columns,
                        tokenizer: tokenizer, n: n))
            }
            self.leaves = resolved
        }

        /// The (negated) bm25f score of `docid` for the prepared query — a lookup per
        /// resolved leaf, no posting decode. Bit-identical to the per-document path:
        /// same leaf order, same `wf = Σ_c weight_c·freq_c` (over allowed columns),
        /// same zero-frequency skip, same `contribution`, same negation.
        func score(docid: Int64, statsCursor: inout Cursor<R>) throws(DBError) -> Double {
            guard !degenerate else { return 0 }
            guard let docLength = try FTSIndex.docLength(&statsCursor, docid: docid) else { return 0 }
            let lengthNorm = FTSScorer.lengthNorm(docLength: docLength, avgdl: avgdl)
            var total = 0.0
            for leaf in leaves {
                guard let perColumn = leaf.perDocFreq[docid] else { continue }
                var weightedFreq = 0.0
                for column in 0..<columns where leaf.allowed?.contains(column) ?? true {
                    weightedFreq += weights[column] * Double(perColumn[column])
                }
                guard weightedFreq > 0 else { continue }
                total += FTSScorer.contribution(
                    idf: leaf.idf, weightedFreq: weightedFreq, lengthNorm: lengthNorm)
            }
            return -total
        }

        // MARK: Leaf resolution (once per query)

        /// Walks the query collecting positive leaf phrases with the columns each may
        /// score in. `NOT` right operands are skipped; `col:` restrictions intersect
        /// into the allowed-column set passed down (nil == all columns). Mirrors the
        /// previous `Scorer.collectLeaves` traversal exactly.
        private static func collectLeaves(
            _ query: FTSQuery, columns allowed: Set<Int>?, record: Catalog.FTSRecord,
            _ visit: (FTSQuery, Set<Int>?) throws(DBError) -> Void
        ) throws(DBError) {
            switch query {
            case .phrase:
                try visit(query, allowed)
            case .and(let lhs, let rhs), .or(let lhs, let rhs):
                try collectLeaves(lhs, columns: allowed, record: record, visit)
                try collectLeaves(rhs, columns: allowed, record: record, visit)
            case .not(let lhs, _):
                try collectLeaves(lhs, columns: allowed, record: record, visit)
            case .column(let names, let inner):
                try collectLeaves(
                    inner, columns: try restrict(allowed, to: names, record: record), record: record, visit)
            }
        }

        private static func restrict(
            _ current: Set<Int>?, to names: [String], record: Catalog.FTSRecord
        ) throws(DBError) -> Set<Int> {
            var resolved = Set<Int>()
            for name in names {
                guard let index = record.definition.columns.firstIndex(of: name) else {
                    throw DBError.sqlRuntime("no such column \(name) in FTS table \(record.definition.name)")
                }
                resolved.insert(index)
            }
            return current.map { $0.intersection(resolved) } ?? resolved
        }

        /// Resolves one positive leaf: its IDF (from the leaf's document frequency)
        /// and a `docid → per-column frequency` table, decoding each posting list
        /// ONCE. Combines what the per-document path computed separately as
        /// `documentFrequency` (df) and `frequencies(docid)` (per-doc tf), so the two
        /// stay consistent and neither re-reads postings per document.
        private static func prepareLeaf(
            _ leaf: FTSQuery, allowed: Set<Int>?, record: Catalog.FTSRecord, resolver: R,
            columns: Int, tokenizer: any FTSTokenizer, n: Double
        ) throws(DBError) -> PreparedLeaf {
            guard case .phrase(let text, let prefix) = leaf else {
                return PreparedLeaf(idf: FTSScorer.idf(df: 0, n: n), allowed: allowed, perDocFreq: [:])
            }
            let tokens = try tokenizer.allTokens(Array(text.utf8)).map(\.term)
            if tokens.isEmpty {
                return PreparedLeaf(idf: FTSScorer.idf(df: 0, n: n), allowed: allowed, perDocFreq: [:])
            }
            if tokens.count == 1 {
                return try prepareTerm(
                    tokens[0], prefix: prefix, allowed: allowed, record: record, resolver: resolver,
                    columns: columns, n: n)
            }
            return try preparePhrase(
                tokens, prefix: prefix, allowed: allowed, record: record, resolver: resolver,
                columns: columns, n: n)
        }

        /// A single-term leaf: df from the dictionary (no prefix) or the prefix
        /// expansion's distinct documents; per-column tf summed across the expansion.
        /// Mirrors `termDocumentFrequency` + `termFrequencies`.
        private static func prepareTerm(
            _ term: [UInt8], prefix: Bool, allowed: Set<Int>?, record: Catalog.FTSRecord, resolver: R,
            columns: Int, n: Double
        ) throws(DBError) -> PreparedLeaf {
            var perDoc: [Int64: [UInt32]] = [:]
            if !prefix {
                let df = try FTSIndex.documentFrequency(resolver, record, term: term)
                if let postings = try FTSIndex.postings(resolver, record, term: term) {
                    perDoc.reserveCapacity(postings.count)
                    for posting in postings {
                        var freq = [UInt32](repeating: 0, count: columns)
                        for column in 0..<min(columns, posting.fieldTFs.count) {
                            freq[column] = posting.fieldTFs[column]
                        }
                        perDoc[posting.docid] = freq
                    }
                }
                return PreparedLeaf(idf: FTSScorer.idf(df: df, n: n), allowed: allowed, perDocFreq: perDoc)
            }
            // Trailing `*`: union the prefix expansion's documents for df, summing each
            // expanded term's per-column tf into the document's frequency (a doc that
            // holds several expansions accumulates, matching `termFrequencies`).
            var docs = Set<Int64>()
            for expansion in try FTSIndex.termsMatchingPrefix(resolver, record, prefix: term) {
                guard let postings = try FTSIndex.postings(resolver, record, term: expansion) else { continue }
                for posting in postings {
                    docs.insert(posting.docid)
                    var freq = perDoc[posting.docid] ?? [UInt32](repeating: 0, count: columns)
                    for column in 0..<min(columns, posting.fieldTFs.count) {
                        freq[column] &+= posting.fieldTFs[column]
                    }
                    perDoc[posting.docid] = freq
                }
            }
            return PreparedLeaf(
                idf: FTSScorer.idf(df: UInt64(docs.count), n: n), allowed: allowed, perDocFreq: perDoc)
        }

        /// A multi-term phrase leaf: df is the documents in which the tokens occur
        /// adjacently (any column); per-column frequency is the adjacency count. Both
        /// derive from each expansion's per-token `[docid: posting]` maps, decoded
        /// once. Mirrors `phraseDocs` + `phraseFrequencies`.
        private static func preparePhrase(
            _ tokens: [[UInt8]], prefix: Bool, allowed: Set<Int>?, record: Catalog.FTSRecord, resolver: R,
            columns: Int, n: Double
        ) throws(DBError) -> PreparedLeaf {
            guard record.definition.detail != .none else {
                // Without positions a phrase cannot be scored per column; it still matched
                // (F3b requires positions for phrases), so it contributes nothing.
                return PreparedLeaf(idf: FTSScorer.idf(df: 0, n: n), allowed: allowed, perDocFreq: [:])
            }
            var docs = Set<Int64>()
            var perDoc: [Int64: [UInt32]] = [:]
            for expanded in try expand(tokens, prefix: prefix, record: record, resolver: resolver) {
                let byToken = try postingsByDoc(expanded, record: record, resolver: resolver)
                guard let first = byToken.first else { continue }
                var candidates = Set(first.keys)
                for map in byToken.dropFirst() { candidates.formIntersection(map.keys) }
                for docid in candidates {
                    let perColumn = adjacencyCounts(byToken, docid: docid, columns: columns)
                    guard perColumn.contains(where: { $0 > 0 }) else { continue }
                    docs.insert(docid)
                    var freq = perDoc[docid] ?? [UInt32](repeating: 0, count: columns)
                    for column in 0..<columns { freq[column] &+= perColumn[column] }
                    perDoc[docid] = freq
                }
            }
            return PreparedLeaf(
                idf: FTSScorer.idf(df: UInt64(docs.count), n: n), allowed: allowed, perDocFreq: perDoc)
        }

        /// Trailing `*` expands the last token over its prefix terms, yielding one
        /// concrete token sequence per expansion; no `*` yields the tokens as-is.
        private static func expand(
            _ tokens: [[UInt8]], prefix: Bool, record: Catalog.FTSRecord, resolver: R
        ) throws(DBError) -> [[[UInt8]]] {
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

        /// Each token's `docid → posting` map (decoded once). An absent token empties
        /// the result (no document can hold the phrase).
        private static func postingsByDoc(
            _ tokens: [[UInt8]], record: Catalog.FTSRecord, resolver: R
        ) throws(DBError) -> [[Int64: FTSPosting]] {
            var byToken: [[Int64: FTSPosting]] = []
            for token in tokens {
                guard let postings = try FTSIndex.postings(resolver, record, term: token) else { return [] }
                var map: [Int64: FTSPosting] = [:]
                for posting in postings { map[posting.docid] = posting }
                byToken.append(map)
            }
            return byToken
        }

        /// Per-column count of consecutive-position phrase hits for `docid`: for each
        /// starting position of the first token in a column, the phrase counts once
        /// when every later token sits at the next position. Identical to the previous
        /// `Scorer.adjacencyCounts`.
        private static func adjacencyCounts(
            _ byToken: [[Int64: FTSPosting]], docid: Int64, columns: Int
        ) -> [UInt32] {
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
