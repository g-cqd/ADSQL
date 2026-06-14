/// SELECT execution over a `PageResolver` (committed reader or write-txn
/// overlay). The single-table pipeline is access-path source → WHERE filter →
/// projection → DISTINCT → ORDER BY → OFFSET/LIMIT (with a LIMIT early-exit
/// when the source order is final); joins add a nested-loop driver that
/// null-extends LEFT non-matches and applies ON during matching, WHERE after.
/// Results are fully materialized before the transaction closure returns.

enum SelectExecutor {
  static func run<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    joinIndexes: [Catalog.IndexRecord?] = [],
    ftsRecords: [String: Catalog.FTSRecord] = [:],
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)? = nil,
    subquery: @escaping SubqueryRunner = rejectSubquery,
    execution: ExecutionOptions = .default,
    mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil
  ) throws(DBError) -> [SQLRow] {
    let evaluator = execution.evaluator
    if plan.isAggregated {
      return try runAggregated(
        plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
        resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution,
        mergeIndexes: mergeIndexes)
    }
    if plan.isJoin {
      return try runJoin(
        plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
        resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution,
        mergeIndexes: mergeIndexes)
    }
    // Index-ordered DISTINCT: emit one row per distinct index-key prefix, decoded
    // straight from the key (no table descent, no dedup set).
    if let name = plan.distinctIndexName, let index, index.definition.name == name {
      return try runDistinctIndex(plan, index: index, resolver: resolver, params: params)
    }
    let table = tables[0]
    let context = RowContext(definitions: tables.map(\.definition))
    let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let bounds = try sliceBounds(plan, params: params)

    // Resolve the access path into a concrete row source, then decide whether
    // its order satisfies ORDER BY (so the sort and a LIMIT early-exit are
    // safe). An index probe whose values do not convert to the column class
    // falls back to a table scan — still correct via the residual WHERE.
    let source = try resolveSource(
      plan, table: table, index: index, ftsRecords: ftsRecords, env: paramsEnv)
    let ordered: Bool
    switch source {
    case .table:
      ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
    case .rowids:
      ordered = plan.accessYieldsOrder
    case .index(_, let list):
      ordered = plan.orderBy.isEmpty || (plan.accessYieldsOrder && list.count <= 1)
    case .fts:
      // The docid set is ascending; the planner sets accessYieldsOrder only
      // when there is no ORDER BY, so otherwise the executor sorts.
      ordered = plan.accessYieldsOrder
    }

    // Early-exit under LIMIT is sound only when the source order is final and
    // no later DISTINCT can drop earlier rows.
    let collectKeys = !ordered && !plan.orderBy.isEmpty
    let sliceEnd: Int? =
      (ordered && !plan.distinct)
      ? bounds.flatMap { b in b.limit.map { b.offset + $0 } } : nil
    // Bounded top-N: an unordered ORDER BY + (small) LIMIT without DISTINCT
    // keeps only offset+limit rows instead of materializing and sorting every
    // match. Larger limits fall back to collect-and-sort.
    let topN: Int? = {
      guard collectKeys, !plan.distinct, let bounds, let limit = bounds.limit, limit >= 1 else {
        return nil
      }
      let bound = bounds.offset + limit
      return bound >= 1 && bound <= 4096 ? bound : nil
    }()
    let dedupRowids: Bool = {
      if case .index(_, let list) = source { return list.count > 1 }
      return false
    }()
    // F6c — block-max WAND ranked top-k: when the leading FTS source is ordered by
    // its bm25 `rank` slot ascending (best first) under a LIMIT, retrieve the
    // top-(offset+limit) by dynamic pruning instead of scoring the whole match set.
    // `k` is offset+limit (the slice drops the offset afterward). Enabled only for
    // `ORDER BY rank[, rowid]` ascending — exactly the heap's score-then-smallest-
    // rowid tiebreak — so the result is identical to score-all; any other shape (or
    // an ineligible query, decided inside) keeps the score-all path. nil = off.
    let ftsRankedTopK: Int? = {
      guard case .fts = source, let topN, isFTSRankAscendingOrder(plan.orderBy) else { return nil }
      return topN
    }()
    // Bounded top-N over a single TEXT ORDER BY column: lets `consume` drop a
    // non-qualifying row by comparing its column bytes in place (no sort-key
    // String) against the worst kept entry. nil = the general `[Value]` path.
    let fastSort: (column: Int, descending: Bool, nocase: Bool)? = {
      guard topN != nil, !plan.distinct, plan.orderBy.count == 1,
        case .boundColumn(let table, let column) = plan.orderBy[0].expr, table == 0,
        plan.binding.tables[0].columnTypes[column] == .text
      else { return nil }
      let collation = plan.orderCollations[0]
      guard collation == .binary || collation == .nocase else { return nil }
      return (column, plan.orderBy[0].descending, collation == .nocase)
    }()

    // A taken rowid/index probe exactly covers its equality conjuncts, so the
    // residual can drop them; a table scan (incl. the coercion fallback) must
    // re-check the full WHERE. The FTS source covers its MATCH conjunct (already
    // stripped from the WHERE at bind time), so any remaining WHERE applies.
    let residual: SQLExpr?
    switch source {
    case .table: residual = plan.whereExpr
    case .rowids, .index, .fts: residual = plan.residualWithoutCovered
    }
    // F6e: for an FTS source, computing the per-doc bm25 score is dead work
    // unless the `rank` slot is actually read — by the projection, ORDER BY, or
    // residual — or WAND needs it. Skipping it makes a membership-only MATCH O(n)
    // instead of O(n²) (FTSScorer.score re-decodes the term's whole list per doc).
    let ftsScoreNeeded: Bool = {
      guard case .fts = source else { return true }
      if ftsRankedTopK != nil { return true }
      func reads(_ e: SQLExpr) -> Bool { exprReferences(e, table: 0, column: ftsRankSlot) }
      if plan.outputs.contains(where: { reads($0.expr) }) { return true }
      if plan.orderBy.contains(where: { reads($0.expr) }) { return true }
      if let residual, reads(residual) { return true }
      return false
    }()
    // Per-row evaluation: compile each expression once (compiled-closures path)
    // or wrap the tree-walk evaluator; an unsupported sub-expression falls back to
    // tree-walk so results are identical regardless of strategy.
    let makeThunk: (SQLExpr) -> CompiledEval.Thunk = { expr in
      if evaluator == .compiledClosures,
        let compiled = CompiledEval.compile(expr, context: context, params: params, env: env)
      {
        return compiled
      }
      return { () throws(DBError) -> Value in try SQLEval.evaluate(expr, env) }
    }
    let accumulator = Accumulator(
      context: context,
      residualThunk: residual.map(makeThunk),
      outputThunks: plan.outputs.map { makeThunk($0.expr) },
      orderBy: plan.orderBy,
      orderThunks: plan.orderBy.map { makeThunk($0.expr) },
      orderCollations: plan.orderCollations, collectKeys: collectKeys,
      sliceEnd: sliceEnd, topN: topN, dedupRowids: dedupRowids,
      distinct: plan.distinct, distinctCollations: plan.outputCollations, fastSort: fastSort)
    unsafe try forEachRow(
      source, table: table, resolver: resolver, ftsRankedTopK: ftsRankedTopK,
      ftsScoreNeeded: ftsScoreNeeded
    ) {
      rowid, span, score throws(DBError) in
      unsafe try accumulator.consume(rowid: rowid, span: span, score: score)
    }

    var rows = accumulator.rows
    var sortKeys = accumulator.sortKeys
    if plan.distinct && !accumulator.streamedDistinct {
      (rows, sortKeys) = deduplicate(
        rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
    }
    // Bounded top-N already holds rows sorted; otherwise sort the collected set.
    if collectKeys && !accumulator.presorted {
      let order = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
      rows = order.map { rows[$0] }
    }
    if let bounds {
      let lower = min(bounds.offset, rows.count)
      let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
      rows = Array(rows[lower..<upper])
    }
    return rows.map { SQLRow(header: plan.header, values: $0) }
  }

  /// Index-ordered DISTINCT: scans `index` in key order and emits one row per
  /// distinct key prefix (the bytes before the 8-byte rowid suffix), decoding the
  /// values straight from the key — no table descent, no dedup set. Since the
  /// index is sorted, equal prefixes are adjacent, so a byte compare against the
  /// previous emitted prefix is enough. The binder selects this path only when
  /// the index's key columns are exactly the (losslessly decodable) DISTINCT
  /// outputs with no WHERE/ORDER BY; LIMIT/OFFSET apply to the emitted rows.
  private static func runDistinctIndex<R: PageResolver>(
    _ plan: BoundSelect, index: Catalog.IndexRecord, resolver: R, params: SQLParameters
  ) throws(DBError) -> [SQLRow] {
    let columnCount = index.definition.columns.count
    var cursor = Cursor(resolver: resolver, tree: index.handle)
    guard try cursor.move(to: .first) else { return [] }
    var rows: [[Value]] = []
    var previous: [UInt8]?
    var hasRow = true
    while hasRow {
      let decoded: [Value]? = unsafe try cursor.withCurrent {
        (key, _) throws(DBError) -> [Value]? in
        guard key.count >= 8 else {
          throw DBError.integrityFailure("index key missing rowid suffix")
        }
        let prefix = unsafe UnsafeRawBufferPointer(rebasing: key[0..<(key.count - 8)])
        if let previous {
          let same = previous.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            unsafe Node.compare(bytes, prefix) == 0
          }
          if same { return nil }  // same distinct group as the previous entry
        }
        previous = unsafe [UInt8](prefix)
        return unsafe try KeyCodec.decode(prefix, columns: columnCount)
      } ?? nil
      if let decoded { rows.append(decoded) }
      hasRow = try cursor.next()
    }
    if let bounds = try sliceBounds(plan, params: params) {
      let lower = min(bounds.offset, rows.count)
      let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
      rows = Array(rows[lower..<upper])
    }
    return rows.map { SQLRow(header: plan.header, values: $0) }
  }

  // MARK: - Row sources

  enum RowSource {
    case table
    case rowids([Int64])
    case index(Catalog.IndexRecord, [IndexBounds])
    /// An FTS5 MATCH source: the docids `FTSMatch.evaluate` returns (ascending),
    /// each scored by bm25f. `query` is the UTF-8 of the resolved MATCH query
    /// string; `weights` are the per-column bm25() weights (already padded to the
    /// FTS column count, all-ones for plain `rank`).
    case fts(Catalog.FTSRecord, query: [UInt8], weights: [Double])
  }

  /// Accumulates surviving rows; `consume` returns false to request early
  /// termination (LIMIT reached on an already-ordered source).
  private final class Accumulator {
    let context: RowContext
    /// Per-row evaluation thunks (tree-walk or compiled), prepared once.
    let residualThunk: CompiledEval.Thunk?
    let outputThunks: [CompiledEval.Thunk]
    /// ORDER BY terms (for the descending flags / count); evaluated via `orderThunks`.
    let orderBy: [SQLOrderingTerm]
    let orderThunks: [CompiledEval.Thunk]
    let orderCollations: [Collation]
    let collectKeys: Bool
    let sliceEnd: Int?
    /// Bounded top-N capacity (offset+limit) for an unordered ORDER BY + LIMIT
    /// without DISTINCT. When set, `rows`/`sortKeys` are kept sorted ascending
    /// and capped, so unkept rows are never projected and the full sort is
    /// avoided. nil = collect everything (the caller sorts).
    let topN: Int?
    /// First-occurrence dedup performed *during* the scan (SELECT DISTINCT on the
    /// single-table path): the projected row's `GroupKey` is inserted as it is
    /// consumed, so only ~distinct rows are ever retained instead of materializing
    /// every input row and deduping afterward. Equivalent to the post-scan
    /// `deduplicate` (same first-occurrence-in-scan-order semantics, same keys), so
    /// the executor skips that pass when `streamedDistinct` is true.
    let distinct: Bool
    let distinctCollations: [Collation]
    /// Single TEXT ORDER BY column for the zero-copy top-N early-drop (nil = the
    /// general `[Value]` sort-key path).
    let fastSort: (column: Int, descending: Bool, nocase: Bool)?
    var seenOutputs: Set<GroupKey> = []
    var seenRowids: Set<Int64>?
    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []

    var presorted: Bool { topN != nil }
    var streamedDistinct: Bool { distinct }

    init(
      context: RowContext, residualThunk: CompiledEval.Thunk?, outputThunks: [CompiledEval.Thunk],
      orderBy: [SQLOrderingTerm], orderThunks: [CompiledEval.Thunk],
      orderCollations: [Collation], collectKeys: Bool,
      sliceEnd: Int?, topN: Int?, dedupRowids: Bool,
      distinct: Bool, distinctCollations: [Collation],
      fastSort: (column: Int, descending: Bool, nocase: Bool)?
    ) {
      self.context = context
      self.residualThunk = residualThunk
      self.outputThunks = outputThunks
      self.orderBy = orderBy
      self.orderThunks = orderThunks
      self.orderCollations = orderCollations
      self.collectKeys = collectKeys
      self.sliceEnd = sliceEnd
      self.topN = topN
      self.seenRowids = dedupRowids ? [] : nil
      self.distinct = distinct
      self.distinctCollations = distinctCollations
      self.fastSort = fastSort
    }

    func consume(rowid: Int64, span: UnsafeRawBufferPointer, score: Double) throws(DBError) -> Bool {
      if seenRowids != nil {
        if seenRowids!.contains(rowid) { return true }
        seenRowids!.insert(rowid)
      }
      unsafe context.load(0, rowid: rowid, span: span, score: score)
      if let residualThunk {
        if SQLEval.truth(try residualThunk()) != .yes { return true }
      }

      if let topN {
        // Fast early-drop: when the buffer is full and ORDER BY is a single TEXT
        // column, compare the candidate's bytes in place against the worst kept
        // entry — dropping a non-qualifying row without allocating a sort-key
        // String. Equivalent to (and superseded by) the `orderBefore` check below.
        if let fastSort, rows.count >= topN,
          try fastDropsCandidate(fastSort, worstKey: sortKeys[topN - 1][0])
        {
          return true
        }
        // Compute the sort key first; only project rows that make the cut.
        var keys: [Value] = []
        keys.reserveCapacity(orderThunks.count)
        for thunk in orderThunks { keys.append(try thunk()) }
        if rows.count >= topN, !orderBefore(keys, sortKeys[topN - 1]) { return true }
        insertSorted(keys, try project())
        return true
      }

      let projected = try project()
      // Stream DISTINCT: drop a row whose projected key was already seen. First
      // occurrence wins (scan order), matching the post-scan `deduplicate`.
      if distinct, !seenOutputs.insert(GroupKey(projected, collations: distinctCollations)).inserted {
        return true
      }
      rows.append(projected)
      if collectKeys {
        var keys: [Value] = []
        keys.reserveCapacity(orderThunks.count)
        for thunk in orderThunks { keys.append(try thunk()) }
        sortKeys.append(keys)
      }
      if let sliceEnd, rows.count >= sliceEnd { return false }
      return true
    }

    private func project() throws(DBError) -> [Value] {
      var projected: [Value] = []
      projected.reserveCapacity(outputThunks.count)
      for thunk in outputThunks { projected.append(try thunk()) }
      return projected
    }

    /// True when the bounded buffer is full and the candidate row (its `fastSort`
    /// column read in place) does NOT qualify for the top-N — letting `consume`
    /// drop it without materializing a sort-key `String`. Returns false (fall
    /// through to the full `[Value]` path) whenever it can't decide in place: a
    /// NULL or unstored candidate, or a non-contiguous/non-text worst key. The
    /// keep/drop rule mirrors `orderBefore` for one column (NULL-first, then DESC).
    private func fastDropsCandidate(
      _ fastSort: (column: Int, descending: Bool, nocase: Bool), worstKey: Value
    ) throws(DBError) -> Bool {
      let comparison: Int? = unsafe try context.slots[0].withTextBytes(at: fastSort.column) {
        (candidate) throws(DBError) -> Int? in
        guard let candidate = unsafe candidate else { return nil }  // NULL/missing → full path
        switch worstKey {
        case .null:
          return 1  // a non-null candidate sorts after a null worst (⇒ all kept are null)
        case .text(let worst):
          return worst.utf8.withContiguousStorageIfAvailable { storage -> Int in
            let worstBytes = UnsafeRawBufferPointer(storage)
            if fastSort.nocase {
              return unsafe SQLCompare.compareUTF8NoCase(candidate, worstBytes)
            }
            return unsafe SQLCompare.compareUTF8(candidate, worstBytes)
          }
        default:
          return nil  // worst not text/null (shouldn't happen for a TEXT column)
        }
      }
      guard let comparison else { return false }  // couldn't decide in place → keep
      let keep = fastSort.descending ? comparison > 0 : comparison < 0
      return !keep
    }

    /// Does sort key `a` order strictly before `b` under ORDER BY?
    private func orderBefore(_ a: [Value], _ b: [Value]) -> Bool {
      for position in orderBy.indices {
        let comparison = orderCompare(a[position], b[position], orderCollations[position])
        if comparison != 0 { return orderBy[position].descending ? comparison > 0 : comparison < 0 }
      }
      return false
    }

    /// Inserts into the ascending bounded buffer, dropping the worst when over
    /// capacity.
    private func insertSorted(_ keys: [Value], _ row: [Value]) {
      var lo = 0
      var hi = rows.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if orderBefore(sortKeys[mid], keys) { lo = mid + 1 } else { hi = mid }
      }
      rows.insert(row, at: lo)
      sortKeys.insert(keys, at: lo)
      if let topN, rows.count > topN {
        rows.removeLast()
        sortKeys.removeLast()
      }
    }
  }

  /// Drives a row source, invoking `body` per `(rowid, recordSpan, score)`. The
  /// span is a zero-copy view into the mapped page, valid only for the duration
  /// of the `body` call; `score` is the bm25 relevance (0 for non-FTS sources).
  /// `body` returns false to stop early.
  static func forEachRow<R: PageResolver>(
    _ source: RowSource, table: Catalog.TableRecord, resolver: R, existenceOnly: Bool = false,
    ftsRankedTopK: Int? = nil, ftsScoreNeeded: Bool = true,
    _ body: (Int64, UnsafeRawBufferPointer, Double) throws(DBError) -> Bool
  ) throws(DBError) {
    switch source {
    case .table:
      var cursor = try RowCursor(
        resolver: resolver, table: table, mode: .table, lowerKey: nil, upperKey: nil)
      unsafe try cursor.forEachRecordSpan { rowid, span throws(DBError) in
        unsafe try body(rowid, span, 0)
      }
    case .rowids(let rowids):
      for rowid in rowids {
        let outcome: Bool? = try Relation.withRowValue(
          resolver, table.handle, key: KeyCodec.rowKey(rowid)
        ) { ref throws(DBError) in
          unsafe try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
            unsafe try body(rowid, span, 0)
          }
        }
        if outcome == false { return }  // nil = no such row → skip
      }
    case .index(let index, let boundsList):
      // Existence-only (an existence-only join inner): drive the index entries
      // directly with NO table descent — `coveringIncludes: []` selects the
      // no-descent branch, serving each entry's (here unread) value span. The
      // rowid still comes from the key; the caller reads no inner column.
      let covering: [String]? = existenceOnly ? [] : nil
      for bounds in boundsList {
        let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
        var cursor = try RowCursor(
          resolver: resolver, table: table, mode: .index(index),
          lowerKey: lower, upperKey: upper, coveringIncludes: covering)
        unsafe try cursor.forEachRecordSpan { rowid, span throws(DBError) in
          unsafe try body(rowid, span, 0)
        }
      }
    case .fts(let record, let queryBytes, let weights):
      // Evaluate the MATCH query to its docid set (F3b), score each by bm25f
      // (F4a), then hand each docid to `body` with an EMPTY span and the score:
      // the FTS table's `RowSlot` is built from the synthetic rowid-alias
      // definition, so `compute` returns `.integer(docid)` for `rowid`, `.real`
      // for `rank`, and never reads the span. The join then descends on
      // `base.id = fts.rowid` exactly as for an ordinary rowid source.
      let query = try FTSQuery.parse(String(decoding: queryBytes, as: UTF8.self))
      // Fetch the corpus aggregate once; pad weights to the FTS column count.
      let global = try FTSIndex.globalStats(resolver, record)
      let columns = record.definition.columns.count
      var resolvedWeights = weights
      if resolvedWeights.count < columns {
        resolvedWeights += Array(repeating: 1.0, count: columns - resolvedWeights.count)
      }
      let empty = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
      // F6c — block-max WAND: a ranked top-k (ORDER BY rank ASC + LIMIT k) over an
      // eligible query shape retrieves the top-k by dynamic pruning, scoring only
      // survivors (identical scores via FTSScorer). nil ⇒ fall back to score-all.
      if let k = ftsRankedTopK,
        let top = try FTSWAND.topK(
          query: query, record: record, resolver: resolver, weights: resolvedWeights,
          global: global, k: k)
      {
        for entry in top {
          if try unsafe !body(entry.docid, empty, entry.score) { return }
        }
        return
      }
      // Score-all: evaluate the MATCH query to its docid set (F3b), score each by
      // bm25f (F4a), then hand each docid to `body` with an EMPTY span and the
      // score: the FTS table's `RowSlot` is built from the synthetic rowid-alias
      // definition, so `compute` returns `.integer(docid)` for `rowid`, `.real`
      // for `rank`, and never reads the span. The join then descends on
      // `base.id = fts.rowid` exactly as for an ordinary rowid source.
      let docids = try FTSMatch.evaluate(query, record: record, resolver: resolver)
      // F6i: resolve the query ONCE (each leaf's df/IDF and per-document
      // frequencies) so the per-document loop is a table lookup, not a re-decode
      // of the term's posting list — nor, for a `foo*` prefix, a per-document re-
      // enumeration of its document frequency, which dominated the score-all path.
      // F6e: a membership-only query (no `rank`/`bm25` referenced) never reads the
      // score, so skip building the scorer entirely.
      let scorer: FTSScorer.PreparedScorer<R>? =
        ftsScoreNeeded
        ? try FTSScorer.PreparedScorer(
          query: query, record: record, resolver: resolver, weights: resolvedWeights,
          global: global)
        : nil
      // One persistent ascending cursor on the stats tree for the whole scan: the
      // docids arrive ascending, so `docLength`'s `seekForward` skips the per-doc
      // root→leaf descent for same-leaf docs (F6n).
      var statsCursor = Cursor(resolver: resolver, tree: record.stats)
      for docid in docids {
        let score = try scorer?.score(docid: docid, statsCursor: &statsCursor) ?? 0
        if try unsafe !body(docid, empty, score) { return }
      }
    }
  }

  /// Resolves the leading table's access plan into a concrete row source for
  /// this execution (probe values may be parameters; an unconvertible probe
  /// falls back to a table scan).
  static func resolveSource(
    _ plan: BoundSelect, table: Catalog.TableRecord, index: Catalog.IndexRecord?,
    ftsRecords: [String: Catalog.FTSRecord], env paramsEnv: SQLEvalEnv
  ) throws(DBError) -> RowSource {
    try resolveAccess(
      plan.access, index: index, table: table, ftsRecords: ftsRecords, env: paramsEnv)
  }

  /// Resolves an access plan into a row source against `env`. For the leading
  /// table `env` is parameters-only; for an index-nested-loop inner table it is
  /// the full row env (the probe values are outer columns, evaluated per outer
  /// row). An unconvertible/absent probe falls back to a scan — still correct
  /// via the residual (single-table WHERE, or the join's ON re-applied).
  static func resolveAccess(
    _ access: AccessPlan, index: Catalog.IndexRecord?, table: Catalog.TableRecord,
    ftsRecords: [String: Catalog.FTSRecord], env: SQLEvalEnv
  ) throws(DBError) -> RowSource {
    switch access {
    case .tableScan:
      return .table
    case .rowid(let exprs):
      return .rowids(try evaluateRowids(exprs, env))
    case .index(_, let probes, _):
      guard let index else { return .table }
      switch try buildIndexBounds(probes, index: index, table: table, env: env) {
      case .scan: return .table
      case .bounds(let list): return .index(index, list)
      }
    case .fts(let name, let queryExpr, let weights):
      guard let record = ftsRecords[name] else {
        throw DBError.noSuchTable(name)
      }
      // The query is a literal/parameter; evaluate it to text → UTF-8. A NULL or
      // non-text query matches nothing (empty bytes parse to an empty query).
      let value = try SQLEval.evaluate(queryExpr, env)
      guard case .text(let text) = value else {
        throw DBError.sqlRuntime("MATCH query must be a text value")
      }
      return .fts(record, query: Array(text.utf8), weights: weights)
    }
  }

}
