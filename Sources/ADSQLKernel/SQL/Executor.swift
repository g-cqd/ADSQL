/// SELECT execution over a `PageResolver` (committed reader or write-txn
/// overlay). The single-table pipeline is access-path source → WHERE filter →
/// projection → DISTINCT → ORDER BY → OFFSET/LIMIT (with a LIMIT early-exit
/// when the source order is final); joins add a nested-loop driver that
/// null-extends LEFT non-matches and applies ON during matching, WHERE after.
/// Results are fully materialized before the transaction closure returns.

/// On-demand row view over a record's bytes *in place* — the bytes are an
/// `UnsafeRawBufferPointer` into the mapped page (or dirty page buffer), set
/// per row by `load` and valid only for the current scan-body scope. Decodes a
/// column only when the evaluator asks for it and caches the result, so a scan
/// that filters on one column never materializes the rest of a rejected row,
/// and never copies the whole record. The rowid-alias column reads back from
/// the rowid, and columns beyond the stored count fall to their schema default
/// (mirroring `Relation.materializeRow`).
// SAFETY (Review 0001 F1): unlike RowView/ValueRef (now `~Escapable`, lifetime-
// checked), this stays `@safe` over a stored raw pointer because the invariant
// is not compiler-enforceable here. `span` is re-pointed by `load` each row and
// read only within that row's scan body; the slot caches decoded `Value`s, not
// the bytes. Column reads are *decoupled* from the scan body — they arrive
// through the per-row `SQLEvalEnv.column` closure (whose `scalarSubquery` field
// is `@escaping`, which a `~Escapable` `RawSpan` cannot be captured into) — so
// the span must be stored, not threaded as a parameter. Enforcing this would
// require routing a `RawSpan` through the whole evaluator. The slot is query-
// internal (`RowContext.slots`) and never escapes the scan loop; its lifetime
// is bounded by the owning `forEach*` call. Owner: the scan driver. Bounds: one
// scan body. Invariant asserted, not enforced.
@safe final class RowSlot {
  private let columns: [ColumnDefinition]
  private let aliasIndex: Int?
  /// The FTS `rank` score column index (slot 1 of the synthetic FTS definition),
  /// if this slot models an FTS table. `compute` returns the per-row `score` for
  /// it without touching the span, parallel to the `aliasIndex → rowid` path.
  private let scoreIndex: Int?
  private(set) var rowid: Int64 = 0
  /// The bm25 relevance score of the current FTS row (`.real(score)` for the
  /// `rank` column). Zero for non-FTS rows, where `scoreIndex` is nil.
  private var score: Double = 0
  private var span = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
  private var cache: [Value?]
  // Incremental cell location: `offsets[i]` is the byte start of stored cell i,
  // filled lazily up to the highest column read. Reused across rows (storage
  // kept), so a sort-key-only scan pays no per-row [Int] allocation and walks
  // only as far as the columns it touches.
  private var offsets: [Int]
  private var locatedCount = 0     // cells whose start is recorded in `offsets`
  private var scanOffset = 0       // byte offset of the next unlocated cell
  private var storedCount = 0
  private var headerParsed = false

  init(table: TableDefinition) {
    self.columns = table.columns
    self.aliasIndex = table.rowidAliasIndex
    self.scoreIndex = table.ftsScoreIndex
    self.cache = Array(repeating: nil, count: table.columns.count)
    self.offsets = []
    self.offsets.reserveCapacity(table.columns.count)
  }

  /// Re-points the slot at a new row's record span; resets the decode state.
  /// `score` is the FTS row's bm25 score (ignored when not an FTS slot). The
  /// span must stay valid for as long as the slot is read (the scan driver
  /// guarantees this within the per-row body).
  func load(rowid: Int64, span: UnsafeRawBufferPointer, score: Double = 0) {
    self.rowid = rowid
    self.score = score
    unsafe self.span = unsafe span
    self.headerParsed = false
    self.locatedCount = 0
    self.offsets.removeAll(keepingCapacity: true)
    for index in cache.indices { cache[index] = nil }
  }

  /// Loads a fully materialized row (no span). The hash-join build side decodes
  /// its rows once into `[Value]` (via `materialize`) and re-serves them during
  /// the probe; every column is pre-cached so `value(at:)` never reads the (nil)
  /// span. `values` must cover all columns (i.e. come from `materialize`).
  func loadMaterialized(rowid: Int64, values: [Value]) {
    self.rowid = rowid
    self.score = 0
    for index in cache.indices { cache[index] = index < values.count ? values[index] : nil }
  }

  func value(at index: Int) throws(DBError) -> Value {
    if let cached = cache[index] { return cached }
    let value = try compute(at: index)
    cache[index] = value
    return value
  }

  /// Zero-copy access to a stored TEXT (resp. BLOB) column's payload bytes in
  /// place — no `String`/`[UInt8]`. `body` gets nil when the column is NULL, a
  /// different storage class, the rowid-alias/score slot, or not stored by a short
  /// row (the caller then falls back to the `Value` path). Valid only within the
  /// call; the span is the same one `compute` reads, so the usual per-row scope
  /// applies. Used by the join's zero-copy probe-key build.
  func withTextBytes<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    if index == aliasIndex || index == scoreIndex { return try body(nil) }
    return unsafe try RecordCodec.withText(at: index, in: span, body)
  }

  func withBlobBytes<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    if index == aliasIndex || index == scoreIndex { return try body(nil) }
    return unsafe try RecordCodec.withBlob(at: index, in: span, body)
  }

  /// All columns as a materialized row — the eager fallback (projection of
  /// `*`, RETURNING) and the property-test oracle against `materializeRow`.
  func materialize() throws(DBError) -> [Value] {
    var values: [Value] = []
    values.reserveCapacity(columns.count)
    for index in columns.indices { values.append(try value(at: index)) }
    return values
  }

  private func compute(at index: Int) throws(DBError) -> Value {
    if index == aliasIndex { return .integer(rowid) }
    // The FTS `rank` slot reads the precomputed score, never the (empty) span.
    if index == scoreIndex { return .real(score) }
    guard let start = try locate(index) else {
      switch columns[index].defaultValue {
      case .value(let value): return value
      case .datetimeNow, nil: return .null
      }
    }
    return unsafe try RecordCodec.decodeCell(span, at: start)
  }

  /// Byte start of stored cell `index`, or nil if beyond the stored count.
  /// Walks (and records) only as far as `index`, reusing prior work.
  private func locate(_ index: Int) throws(DBError) -> Int? {
    if !headerParsed {
      var offset = 0
      storedCount = unsafe try RecordCodec.readHeader(span, &offset)
      scanOffset = offset
      headerParsed = true
    }
    if index >= storedCount { return nil }
    while locatedCount <= index {
      offsets.append(scanOffset)
      unsafe try RecordCodec.skipCell(span, &scanOffset)
      locatedCount += 1
    }
    return offsets[index]
  }
}

enum SelectExecutor {
  static func run<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    joinIndexes: [Catalog.IndexRecord?] = [],
    ftsRecords: [String: Catalog.FTSRecord] = [:],
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)? = nil,
    subquery: @escaping SubqueryRunner = rejectSubquery,
    execution: ExecutionOptions = .default
  ) throws(DBError) -> [SQLRow] {
    let evaluator = execution.evaluator
    if plan.isAggregated {
      return try runAggregated(
        plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
        resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution)
    }
    if plan.isJoin {
      return try runJoin(
        plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
        resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution)
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

  private enum RowSource {
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
  private static func forEachRow<R: PageResolver>(
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
  private static func resolveSource(
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
  private static func resolveAccess(
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

  // MARK: - Joins (nested loop, null-extension)

  /// Visits every post-WHERE composite row, loading `context` so `body` can
  /// read columns through the binding. Single-table queries scan the access
  /// path; joins drive a right-recursive nested loop — ON filters during
  /// matching, WHERE applies at the leaf (after any LEFT null-extension), and
  /// LEFT emits one null-extended row when the right side has no match.
  private static func forEachFilteredRow<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
    resolver: R, context: RowContext, env: SQLEvalEnv, paramsEnv: SQLEvalEnv,
    execution: ExecutionOptions = .default,
    _ body: () throws(DBError) -> Void
  ) throws(DBError) {
    func passesWhere() throws(DBError) -> Bool {
      guard let predicate = plan.whereExpr else { return true }
      return SQLEval.truth(try SQLEval.evaluate(predicate, env)) == .yes
    }

    guard plan.isJoin else {
      let source = try resolveSource(
        plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
      unsafe try forEachRow(source, table: tables[0], resolver: resolver) {
        rowid, span, score throws(DBError) in
        unsafe context.load(0, rowid: rowid, span: span, score: score)
        if try passesWhere() { try body() }
        return true
      }
      return
    }

    // Merge join (existence/COUNT fast path), and the plan `.auto` chooses when
    // eligible: it is unconditionally cheaper than the nested loop here (one ordered
    // index pass vs M per-outer probes), so the cost choice is just "merge if
    // eligible". `.auto` falls through to the nested loop when ineligible; hash is
    // not auto-selected (it loses on the symmetric self-join — finding #1 — pending
    // a build-side cost estimate). Returns false when ineligible.
    if execution.join == .merge || execution.join == .auto,
      try runMergeJoin(
        plan, tables: tables, joinIndexes: joinIndexes, resolver: resolver, context: context,
        emit: { () throws(DBError) in if try passesWhere() { try body() } })
    {
      return
    }

    // Hash join (selected, eligible 2-table INNER equi-join): build the inner,
    // probe the outer — O(M+N), no per-outer index descent. Returns false when
    // ineligible, falling through to the nested-loop driver below.
    if execution.join == .hash,
      try runInnerHashJoin(
        plan, tables: tables, index: index, ftsRecords: ftsRecords, resolver: resolver,
        context: context, env: env, paramsEnv: paramsEnv,
        budgetBytes: execution.hashJoinMemoryBudgetBytes,
        emit: { () throws(DBError) in if try passesWhere() { try body() } })
    {
      return
    }

    // Reused across outer rows (and join depths — each `fastExistence` builds and
    // seeks before recursing, freeing it for the next depth). An empty span for
    // the defensive existence-hit load (the inner slot is never read).
    var probeKeyBuffer: [UInt8] = []
    probeKeyBuffer.reserveCapacity(64)
    let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)

    func descend(_ depth: Int) throws(DBError) {
      if depth == tables.count {
        if try passesWhere() { try body() }
        return
      }
      let join = plan.joins[depth - 1]
      let joinIndex = depth - 1 < joinIndexes.count ? joinIndexes[depth - 1] : nil
      // Fast existence: a UNIQUE-index full-key equality probe on an existence-only
      // inner reduces to one seek with a zero-copy key — no bounds, cursor, table
      // descent, or ON re-check. nil ⇒ ineligible → the general path below.
      if join.innerExistenceOnly, let joinIndex,
        let hit = try fastExistence(
          join: join, index: joinIndex, table: tables[depth],
          context: context, env: env, resolver: resolver, buffer: &probeKeyBuffer)
      {
        if hit {
          unsafe context.load(depth, rowid: 0, span: emptySpan)
          try descend(depth + 1)
        } else if join.kind == .left {
          context.setNull(depth)
          try descend(depth + 1)
        }
        return
      }
      var matched = false
      // Index-nested-loop: probe the inner table's index with the outer row's
      // value (a superset); the ON below is the residual. Falls back to a full
      // inner scan when `join.access` is `.tableScan`.
      // A missing index record (caller didn't resolve one) degrades an
      // `.index` probe to a scan; `.rowid` probes need no record.
      let innerSource = try resolveAccess(
        join.access, index: joinIndex, table: tables[depth], ftsRecords: ftsRecords, env: env)
      // Existence-only is sound only while the access stays an actual probe: an
      // unconvertible value degrades it to a full scan (a superset), which must
      // re-apply the ON. So gate on the *runtime* source, not just the plan flag.
      let existence: Bool
      switch innerSource {
      case .index, .rowids: existence = join.innerExistenceOnly
      case .table, .fts: existence = false
      }
      unsafe try forEachRow(
        innerSource, table: tables[depth], resolver: resolver, existenceOnly: existence
      ) {
        rowid, span, score throws(DBError) in
        unsafe context.load(depth, rowid: rowid, span: span, score: score)
        // Existence-only: the probe already enforces the whole ON and no inner
        // column is read, so skip the (empty-span) re-evaluation.
        if existence {
          matched = true
          try descend(depth + 1)
        } else if SQLEval.truth(try SQLEval.evaluate(join.on, env)) == .yes {
          matched = true
          try descend(depth + 1)
        }
        return true
      }
      if join.kind == .left && !matched {
        context.setNull(depth)
        try descend(depth + 1)
      }
    }

    let outerSource = try resolveSource(
      plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
    unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
      rowid, span, score throws(DBError) in
      unsafe context.load(0, rowid: rowid, span: span, score: score)
      try descend(1)
      return true
    }
  }

  /// Single-seek existence for a UNIQUE-index full-key equality probe on an
  /// existence-only join inner. Builds the probe key (zero-copy from the outer
  /// columns' page bytes where possible) into the reused `buffer`, then checks the
  /// index for a matching entry — no bounds, no `RowCursor`, no table descent.
  /// Returns nil when ineligible (caller uses the general path); `.some(hit)` when
  /// existence was resolved. UNIQUE-only: existence (descend once) preserves join
  /// cardinality, while non-unique fan-out keeps the enumerating existence path.
  private static func fastExistence<R: PageResolver>(
    join: BoundJoin, index: Catalog.IndexRecord, table: Catalog.TableRecord,
    context: RowContext, env: SQLEvalEnv, resolver: R, buffer: inout [UInt8]
  ) throws(DBError) -> Bool? {
    guard index.definition.unique,
      case .index(let name, let probes, _) = join.access,
      name == index.definition.name, probes.count == 1,
      probes[0].trailing == nil,
      probes[0].equality.count == index.definition.columns.count
    else { return nil }
    let tableColumns = index.definition.columns.compactMap { table.definition.columnIndex(of: $0) }
    guard tableColumns.count == index.definition.columns.count else { return nil }
    let collations = Relation.indexCollations(index.definition, table: table.definition)

    buffer.removeAll(keepingCapacity: true)
    for (position, expr) in probes[0].equality.enumerated() {
      let idxType = table.definition.columns[tableColumns[position]].type
      guard try appendProbeField(
        expr, idxType: idxType, collation: collations[position],
        context: context, env: env, into: &buffer)
      else { return nil }  // non-column / class mismatch / NULL / NaN → general path
    }

    var cursor = Cursor(resolver: resolver, tree: index.handle)
    let prefixLen = buffer.count
    // `withUnsafeBytes` is untyped-rethrows; capture into a `Result` (as
    // `Relation.firstRowid` does) to stay in `throws(DBError)`.
    var outcome: Result<Bool, DBError> = .success(false)
    buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        guard cursor.isValid else { return }
        // A4: stored index keys are `columns ++ 8-byte rowid`, so `seek` never
        // reports an exact hit on the column prefix — verify the entry's prefix
        // equals the probe (UNIQUE ⇒ at most one such entry).
        outcome = .success(
          unsafe try cursor.withCurrent { (key, _) throws(DBError) -> Bool in
            guard key.count == prefixLen + 8 else { return false }
            return unsafe raw.elementsEqual(UnsafeRawBufferPointer(rebasing: key[0..<prefixLen]))
          } ?? false)
      } catch {
        outcome = .failure(error)
      }
    }
    return try outcome.get()
  }

  /// Encodes one equality-probe field into `buffer` directly from the outer
  /// column's bytes (TEXT/BLOB zero-copy; INTEGER/REAL from the cached value),
  /// byte-identical to `KeyCodec.append`. Returns false to fall back to the general
  /// (Value-coercing) path: a non-`.boundColumn` expr, an outer storage class that
  /// differs from the index column's, a null-extended outer, a NULL/absent value,
  /// or NaN.
  private static func appendProbeField(
    _ expr: SQLExpr, idxType: ColumnType, collation: Collation,
    context: RowContext, env: SQLEvalEnv, into buffer: inout [UInt8]
  ) throws(DBError) -> Bool {
    guard case .boundColumn(let outerTable, let outerCol) = expr,
      env.boundColumnType(outerTable, outerCol) == idxType,
      !context.nullExtended[outerTable]
    else { return false }
    let slot = context.slots[outerTable]
    switch idxType {
    case .text:
      return unsafe try slot.withTextBytes(at: outerCol) { bytes in
        guard let bytes = unsafe bytes else { return false }
        unsafe KeyCodec.appendTextBytes(bytes, collation: collation, to: &buffer)
        return true
      }
    case .blob:
      return unsafe try slot.withBlobBytes(at: outerCol) { bytes in
        guard let bytes = unsafe bytes else { return false }
        unsafe KeyCodec.appendBlobBytes(bytes, to: &buffer)
        return true
      }
    case .integer:
      guard case .integer(let value) = try slot.value(at: outerCol) else { return false }
      KeyCodec.appendInteger(value, to: &buffer)
      return true
    case .real:
      guard case .real(let value) = try slot.value(at: outerCol), !value.isNaN else { return false }
      try KeyCodec.appendReal(value, to: &buffer)
      return true
    }
  }

  /// Hash join for a 2-table INNER equi-join: builds a hash of the inner table
  /// keyed by the equi-join columns, then probes with each outer row — O(M+N), no
  /// per-outer index descent. Produces the same composite `RowContext` state as the
  /// nested loop, so `emit` (WHERE + projection/aggregation) is unchanged. Returns
  /// false when ineligible (not a single INNER join, no usable same-class/collation
  /// column equi key, or the build exceeds `budgetBytes`) → caller uses nested loop.
  ///
  /// Equi keys are extracted from the (already-bound) ON and key a `GroupKey`,
  /// whose equality matches SQL `=` for same-class/collation columns (no false
  /// negatives). Non-equi ON conjuncts are re-checked per match. A NULL probe key
  /// matches nothing (SQL `=` is unknown with NULL).
  private static func runInnerHashJoin<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    ftsRecords: [String: Catalog.FTSRecord], resolver: R,
    context: RowContext, env: SQLEvalEnv, paramsEnv: SQLEvalEnv,
    budgetBytes: Int, emit: () throws(DBError) -> Void
  ) throws(DBError) -> Bool {
    guard plan.joins.count == 1, plan.joins[0].kind == .inner else { return false }
    let join = plan.joins[0]
    let innerDepth = join.table
    let binding = plan.binding

    var equiInner: [Int] = []
    var equiOuter: [SQLExpr] = []
    var equiCollations: [Collation] = []
    var residualConjuncts: [SQLExpr] = []
    for conjunct in andConjuncts(join.on) {
      if let key = hashEquiKey(conjunct, innerDepth: innerDepth, binding: binding) {
        equiInner.append(key.innerColumn)
        equiOuter.append(key.outerColumn)
        equiCollations.append(key.collation)
      } else {
        residualConjuncts.append(conjunct)
      }
    }
    guard !equiInner.isEmpty else { return false }
    let onResidual: SQLExpr? =
      residualConjuncts.isEmpty
      ? nil : residualConjuncts.dropFirst().reduce(residualConjuncts[0]) { .binary(.and, $0, $1) }

    // SEMI-JOIN: when the inner is existence-only (no inner column is read by the
    // query) and the ON is pure equi (no residual), the inner row *values* are never
    // needed — build per-key COUNTS instead of materializing every inner row, then
    // emit `count` times per matching outer. Avoids the O(inner-rows) materialization
    // that makes the plain hash the wrong tool for a large symmetric existence join
    // (findings #1/#3); cardinality is preserved (COUNT(*) = Σ matched run lengths).
    if join.innerExistenceOnly, onResidual == nil {
      var counts: [GroupKey: Int] = [:]
      unsafe try forEachRow(.table, table: tables[innerDepth], resolver: resolver) {
        rowid, span, score throws(DBError) in
        unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
        var keyValues: [Value] = []
        keyValues.reserveCapacity(equiInner.count)
        for column in equiInner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
        counts[GroupKey(keyValues, collations: equiCollations), default: 0] += 1
        return true
      }
      let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
      let outerSource = try resolveSource(
        plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
      unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
        rowid, span, score throws(DBError) in
        unsafe context.load(0, rowid: rowid, span: span, score: score)
        var probeValues: [Value] = []
        probeValues.reserveCapacity(equiOuter.count)
        for expr in equiOuter { probeValues.append(try SQLEval.evaluate(expr, env)) }
        if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
        guard let count = counts[GroupKey(probeValues, collations: equiCollations)] else { return true }
        unsafe context.load(innerDepth, rowid: 0, span: emptySpan)
        for _ in 0..<count { try emit() }
        return true
      }
      return true
    }

    // BUILD: full scan of the inner table → hash[inner equi key] = [(rowid, full row)].
    var hash: [GroupKey: [(rowid: Int64, values: [Value])]] = [:]
    var approxBytes = 0
    var overBudget = false
    let innerTable = tables[innerDepth]
    unsafe try forEachRow(.table, table: innerTable, resolver: resolver) {
      rowid, span, score throws(DBError) in
      unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
      var keyValues: [Value] = []
      keyValues.reserveCapacity(equiInner.count)
      for column in equiInner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
      let values = try context.slots[innerDepth].materialize()
      hash[GroupKey(keyValues, collations: equiCollations), default: []].append((rowid, values))
      approxBytes += 24 + values.count * 24
      if approxBytes > budgetBytes { overBudget = true; return false }
      return true
    }
    if overBudget { return false }  // build emitted nothing → caller falls back to nested loop

    // PROBE: scan the outer (leading) source; look up each outer row's matches.
    let outerSource = try resolveSource(
      plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
    unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
      rowid, span, score throws(DBError) in
      unsafe context.load(0, rowid: rowid, span: span, score: score)
      var probeValues: [Value] = []
      probeValues.reserveCapacity(equiOuter.count)
      for expr in equiOuter { probeValues.append(try SQLEval.evaluate(expr, env)) }
      if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
      guard let matches = hash[GroupKey(probeValues, collations: equiCollations)] else { return true }
      for match in matches {
        context.loadMaterialized(innerDepth, rowid: match.rowid, values: match.values)
        if let onResidual, SQLEval.truth(try SQLEval.evaluate(onResidual, env)) != .yes { continue }
        try emit()
      }
      return true
    }
    return true
  }

  /// Merge-join existence/COUNT fast path (RFC 0009 H4). A 2-table INNER
  /// existence self-equi-join on a **UNIQUE, NOT-NULL, single-column** index needs
  /// no per-outer inner probe: each outer row matches exactly the one inner row
  /// with the same key (itself), so a single ordered pass over the shared index
  /// emits once per entry — O(N) byte walk, no descent, no materialization
  /// (`COUNT(*)` = the row count). UNIQUE + NOT-NULL rules out dup-run cross-products
  /// and NULL non-matches, so the result is provably identical to the nested loop.
  /// Returns false (→ the proven nested-loop driver) for any shape outside this
  /// subset; the general 2-table / dup-run / nullable merge is a later slice.
  private static func runMergeJoin<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], joinIndexes: [Catalog.IndexRecord?],
    resolver: R, context: RowContext, emit: () throws(DBError) -> Void
  ) throws(DBError) -> Bool {
    guard plan.joins.count == 1, plan.joins[0].kind == .inner else { return false }
    let join = plan.joins[0]
    guard join.innerExistenceOnly, plan.isAggregated, plan.whereExpr == nil,
      !plan.finalizationReferencedTables.contains(0), join.table == 1,
      tables.count == 2, tables[0].tableId == tables[1].tableId,  // self-join (shared index)
      let idx = joinIndexes.first ?? nil,
      idx.definition.unique, idx.definition.columns.count == 1,
      let idxCol = tables[0].definition.columnIndex(of: idx.definition.columns[0]),
      tables[0].definition.columns[idxCol].notNull,
      let key = hashEquiKey(join.on, innerDepth: 1, binding: plan.binding),
      key.innerColumn == idxCol,
      case .boundColumn(let outerTable, let outerColumn) = key.outerColumn,
      outerTable == 0, outerColumn == idxCol
    else { return false }

    // Neither table's columns are read (existence inner + COUNT(*)-style outer), so
    // load defensive empty spans and emit once per index entry in key order.
    let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    unsafe context.load(0, rowid: 0, span: emptySpan)
    unsafe context.load(1, rowid: 0, span: emptySpan)
    var cursor = Cursor(resolver: resolver, tree: idx.handle)
    var positioned = try cursor.move(to: .first)
    while positioned {
      try emit()
      positioned = try cursor.next()
    }
    return true
  }

  private static func andConjuncts(_ expr: SQLExpr) -> [SQLExpr] {
    if case .binary(.and, let l, let r) = expr { return andConjuncts(l) + andConjuncts(r) }
    return [expr]
  }

  /// A hashable equi-join conjunct `inner.col = outer.col` (either operand order)
  /// where both are bound columns of the SAME storage class and collation — so a
  /// `GroupKey` match equals SQL `=` (no affinity coercion). nil otherwise.
  private static func hashEquiKey(
    _ conjunct: SQLExpr, innerDepth: Int, binding: QueryBinding
  ) -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)? {
    guard case .binary(.eq, let lhs, let rhs) = conjunct else { return nil }
    func pair(_ innerSide: SQLExpr, _ outerSide: SQLExpr)
      -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)?
    {
      guard case .boundColumn(let it, let ic) = innerSide, it == innerDepth,
        case .boundColumn(let ot, let oc) = outerSide, ot < innerDepth,
        binding.tables[it].columnTypes[ic] == binding.tables[ot].columnTypes[oc],
        binding.tables[it].columnCollations[ic] == binding.tables[ot].columnCollations[oc]
      else { return nil }
      return (ic, outerSide, binding.tables[it].columnCollations[ic])
    }
    return pair(lhs, rhs) ?? pair(rhs, lhs)
  }

  private static func runJoin<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
    execution: ExecutionOptions = .default
  ) throws(DBError) -> [SQLRow] {
    let context = RowContext(definitions: tables.map(\.definition))
    let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let collectKeys = !plan.orderBy.isEmpty

    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []
    try forEachFilteredRow(
      plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
      resolver: resolver, context: context, env: env, paramsEnv: paramsEnv, execution: execution
    ) { () throws(DBError) in
      var projected: [Value] = []
      projected.reserveCapacity(plan.outputs.count)
      for output in plan.outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
      rows.append(projected)
      if collectKeys {
        var keys: [Value] = []
        for term in plan.orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        sortKeys.append(keys)
      }
    }

    if plan.distinct {
      (rows, sortKeys) = deduplicate(
        rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
    }
    if collectKeys {
      let order = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
      rows = order.map { rows[$0] }
    }
    if let bounds = try sliceBounds(plan, params: params) {
      let lower = min(bounds.offset, rows.count)
      let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
      rows = Array(rows[lower..<upper])
    }
    return rows.map { SQLRow(header: plan.header, values: $0) }
  }

  // MARK: - Aggregation (GROUP BY / COUNT / SUM / HAVING)

  private static func runAggregated<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
    execution: ExecutionOptions = .default
  ) throws(DBError) -> [SQLRow] {
    let context = RowContext(definitions: tables.map(\.definition))
    let scanEnv = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let columnCounts = plan.binding.tables.map(\.columnNames.count)
    let noGroupBy = plan.groupBy.isEmpty

    var order: [GroupKey] = []
    var groups: [GroupKey: (accumulators: GroupAccumulators, representative: [[Value]])] = [:]

    // An aggregate with no GROUP BY always produces exactly one row (COUNT 0,
    // SUM NULL over an empty input), so seed the single implicit group.
    let implicitKey = GroupKey([], collations: [])
    if noGroupBy {
      let empty = columnCounts.map { Array(repeating: Value.null, count: $0) }
      groups[implicitKey] = (GroupAccumulators(specs: plan.aggregates), empty)
      order.append(implicitKey)
    }

    try forEachFilteredRow(
      plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
      resolver: resolver, context: context, env: scanEnv, paramsEnv: paramsEnv, execution: execution
    ) { () throws(DBError) in
      let key: GroupKey
      if noGroupBy {
        key = implicitKey
      } else {
        var parts: [Value] = []
        for expr in plan.groupBy { parts.append(try SQLEval.evaluate(expr, scanEnv)) }
        key = GroupKey(parts, collations: plan.groupCollations)
      }
      if groups[key] == nil {
        var representative: [[Value]] = []
        for table in tables.indices {
          // Skip materializing a table whose representative no output/HAVING/
          // ORDER BY reads (e.g. COUNT(*)). Required for an existence-only inner,
          // whose slot holds an empty span — decoding it would be wrong.
          let needed = plan.finalizationReferencedTables.contains(table)
          representative.append(
            (needed && !context.nullExtended[table])
              ? try context.slots[table].materialize()
              : Array(repeating: Value.null, count: columnCounts[table]))
        }
        groups[key] = (GroupAccumulators(specs: plan.aggregates), representative)
        order.append(key)
      }
      try groups[key]!.accumulators.update(scanEnv)
    }

    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []
    let collectKeys = !plan.orderBy.isEmpty
    for key in order {
      let group = groups[key]!
      let env = aggregateEnv(
        plan.binding, representative: group.representative,
        accumulators: group.accumulators, params: params)
      if let having = plan.having {
        if SQLEval.truth(try SQLEval.evaluate(having, env)) != .yes { continue }
      }
      var projected: [Value] = []
      projected.reserveCapacity(plan.outputs.count)
      for output in plan.outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
      rows.append(projected)
      if collectKeys {
        var keys: [Value] = []
        for term in plan.orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        sortKeys.append(keys)
      }
    }

    if plan.distinct {
      (rows, sortKeys) = deduplicate(
        rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
    }
    if collectKeys {
      let permutation = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
      rows = permutation.map { rows[$0] }
    }
    if let bounds = try sliceBounds(plan, params: params) {
      let lower = min(bounds.offset, rows.count)
      let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
      rows = Array(rows[lower..<upper])
    }
    return rows.map { SQLRow(header: plan.header, values: $0) }
  }

  /// Finalization env for one group: column references read the group's
  /// representative row; `aggregateResult` slots read the accumulators.
  private static func aggregateEnv(
    _ binding: QueryBinding, representative: [[Value]], accumulators: GroupAccumulators,
    params: SQLParameters
  ) -> SQLEvalEnv {
    SQLEvalEnv(
      parameter: { parameter throws(DBError) in try params.lookup(parameter) },
      column: { (qualifier, name, _) throws(DBError) in
        guard let (table, column) = binding.resolve(qualifier: qualifier, name: name) else {
          throw DBError.noSuchColumn(table: qualifier ?? binding.tables[0].table, column: name)
        }
        return representative[table][column]
      },
      collationOf: { (qualifier, name) in
        binding.resolve(qualifier: qualifier, name: name)
          .map { binding.tables[$0.table].columnCollations[$0.column] }
      },
      columnTypeOf: { (qualifier, name) in
        binding.resolve(qualifier: qualifier, name: name)
          .map { binding.tables[$0.table].columnTypes[$0.column] }
      },
      boundColumn: { (table, column) throws(DBError) in representative[table][column] },
      boundCollation: { (table, column) in binding.tables[table].columnCollations[column] },
      boundColumnType: { (table, column) in binding.tables[table].columnTypes[column] },
      scalarSubquery: { _ throws(DBError) in
        throw DBError.sqlUnsupported("subquery (arrives in a later slice)")
      },
      aggregateValue: { slot throws(DBError) in accumulators.result(slot) })
  }

  // MARK: - Probe evaluation & type-boundary coercion

  private static func evaluateRowids(
    _ exprs: [SQLExpr], _ env: SQLEvalEnv
  ) throws(DBError) -> [Int64] {
    var rowids: [Int64] = []
    var seen = Set<Int64>()
    for expr in exprs {
      let value = try SQLEval.evaluate(expr, env)
      let rowid: Int64?
      switch value {
      case .integer(let v): rowid = v
      case .real(let d) where d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18:
        rowid = Int64(d)
      default: rowid = nil  // a non-integral rowid matches no row
      }
      if let rowid, seen.insert(rowid).inserted { rowids.append(rowid) }
    }
    return rowids
  }

  private enum BuiltBounds {
    case scan                  // probe value could not be converted; fall back
    case bounds([IndexBounds]) // empty probes already dropped
  }

  private static func buildIndexBounds(
    _ probes: [IndexProbe], index: Catalog.IndexRecord, table: Catalog.TableRecord,
    env: SQLEvalEnv
  ) throws(DBError) -> BuiltBounds {
    let columns = index.definition.columns.compactMap { table.definition.columnIndex(of: $0) }
    guard columns.count == index.definition.columns.count else { return .scan }
    let types = columns.map { table.definition.columns[$0].type }

    var built: [IndexBounds] = []
    for probe in probes {
      var equalityValues: [Value] = []
      var empty = false
      for (position, expr) in probe.equality.enumerated() {
        switch coerceEquality(try SQLEval.evaluate(expr, env), to: types[position]) {
        case .use(let value): equalityValues.append(value)
        case .empty: empty = true
        case .giveUp: return .scan
        }
        if empty { break }
      }
      if empty { continue }

      guard let trailing = probe.trailing else {
        built.append(.prefix(equalityValues))
        continue
      }
      let rangeType = types[equalityValues.count]
      switch trailing {
      case .range(let lower, let upper):
        let lowerBound = try coerceBound(lower, to: rangeType, env: env)
        let upperBound = try coerceBound(upper, to: rangeType, env: env)
        let lowerList = lowerBound.map { equalityValues + [$0.value] } ?? equalityValues
        let upperList = upperBound.map { equalityValues + [$0.value] } ?? equalityValues
        built.append(
          .range(
            lower: lowerList, upper: upperList,
            lowerOpen: lowerBound.map { !$0.inclusive } ?? false,
            upperOpen: upperBound.map { !$0.inclusive } ?? false))
      }
    }
    return .bounds(built)
  }

  private enum Coerced {
    case use(Value)
    case empty   // distinct storage classes never compare equal: no rows
    case giveUp  // unsafe to convert (e.g. inexact int→real): fall back to scan
  }

  /// An equality probe value coerced to a column's strict class.
  private static func coerceEquality(_ value: Value, to type: ColumnType) -> Coerced {
    if value.columnType == type { return .use(value) }
    switch type {
    case .integer:
      if case .real(let d) = value {
        if d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18 {
          return .use(.integer(Int64(d)))
        }
        return .empty  // no integer equals a non-integral real
      }
      return .empty
    case .real:
      if case .integer(let i) = value {
        if let d = Double(exactly: i) { return .use(.real(d)) }
        return .giveUp  // |i| > 2^53: converting could match the wrong real
      }
      return .empty
    case .text, .blob:
      return .empty
    }
  }

  /// A range bound applies to the index only when it matches the column's
  /// class; otherwise the bound is dropped (that side stays unbounded) and the
  /// residual WHERE enforces it.
  private static func coerceBound(
    _ bound: BoundExpr?, to type: ColumnType, env: SQLEvalEnv
  ) throws(DBError) -> (value: Value, inclusive: Bool)? {
    guard let bound else { return nil }
    let value = try SQLEval.evaluate(bound.expr, env)
    guard value.columnType == type else { return nil }
    return (value, bound.inclusive)
  }

  // MARK: - Compounds (UNION / UNION ALL)

  /// First-occurrence dedup of complete result rows under per-column
  /// collations (UNION semantics), via the canonical group key.
  static func distinctRows(_ rows: [[Value]], collations: [Collation]) -> [[Value]] {
    var seen = Set<GroupKey>()
    var out: [[Value]] = []
    out.reserveCapacity(rows.count)
    for row in rows where seen.insert(GroupKey(row, collations: collations)).inserted {
      out.append(row)
    }
    return out
  }

  /// Applies a compound's ORDER BY (by result-column index) and LIMIT/OFFSET
  /// to the combined rows, then wraps them with the shared header.
  static func finishCompound(
    _ rows: [[Value]], compound: BoundCompound, params: SQLParameters
  ) throws(DBError) -> [SQLRow] {
    var result = rows
    if !compound.order.isEmpty {
      let terms = compound.order
      let permutation = result.indices.sorted { lhs, rhs in
        for term in terms {
          let comparison = orderCompare(result[lhs][term.index], result[rhs][term.index], term.collation)
          if comparison != 0 { return term.descending ? comparison > 0 : comparison < 0 }
        }
        return lhs < rhs
      }
      result = permutation.map { result[$0] }
    }
    if compound.limit != nil || compound.offset != nil {
      let env = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
      // Cap so `lower + limit` below can't overflow (Swift `+` traps).
      let bound = Int.max / 4
      var offset = 0
      if let offsetExpr = compound.offset, let value = try boundValue(offsetExpr, env), value > 0 {
        offset = min(Int(clamping: value), bound)
      }
      var limit: Int?
      if let limitExpr = compound.limit, let value = try boundValue(limitExpr, env), value >= 0 {
        limit = min(Int(clamping: value), bound)
      }
      let lower = min(offset, result.count)
      let upper = limit.map { min(lower + $0, result.count) } ?? result.count
      result = Array(result[lower..<upper])
    }
    return result.map { SQLRow(header: compound.header, values: $0) }
  }

  // MARK: - Evaluation environment

  /// The live row for each table in a query, with per-table null-extension for
  /// LEFT joins. Column reads route here through the binding's resolver.
  final class RowContext {
    let slots: [RowSlot]
    var nullExtended: [Bool]

    init(definitions: [TableDefinition]) {
      self.slots = definitions.map { RowSlot(table: $0) }
      self.nullExtended = Array(repeating: false, count: definitions.count)
    }

    func load(_ table: Int, rowid: Int64, span: UnsafeRawBufferPointer, score: Double = 0) {
      nullExtended[table] = false
      unsafe slots[table].load(rowid: rowid, span: span, score: score)
    }
    /// Loads a materialized (span-less) row into a table slot — the hash-join
    /// build side re-serving a decoded row during probe.
    func loadMaterialized(_ table: Int, rowid: Int64, values: [Value]) {
      nullExtended[table] = false
      slots[table].loadMaterialized(rowid: rowid, values: values)
    }
    func setNull(_ table: Int) { nullExtended[table] = true }

    func value(table: Int, column: Int) throws(DBError) -> Value {
      nullExtended[table] ? .null : try slots[table].value(at: column)
    }
  }

  /// Runs a correlated scalar subquery against the current outer row; provided
  /// by the statement layer (which has transaction/schema access).
  typealias SubqueryRunner =
    (SQLSelect, RowContext, QueryBinding) throws(DBError) -> Value

  static func rejectSubquery(
    _: SQLSelect, _: RowContext, _: QueryBinding
  ) throws(DBError) -> Value {
    throw DBError.sqlUnsupported("subquery in this context")
  }

  private static func rowEnv(
    _ plan: BoundSelect, context: RowContext, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)?,
    subquery: @escaping SubqueryRunner
  ) -> SQLEvalEnv {
    let binding = plan.binding
    return SQLEvalEnv(
      parameter: { parameter throws(DBError) in try params.lookup(parameter) },
      column: { (qualifier, name, _) throws(DBError) in
        // The subquery's own tables first, then the correlated outer row.
        if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
          return try context.value(table: table, column: column)
        }
        if let outer, let (table, column) = outer.binding.resolve(qualifier: qualifier, name: name) {
          return try outer.context.value(table: table, column: column)
        }
        throw DBError.noSuchColumn(table: qualifier ?? binding.tables[0].table, column: name)
      },
      collationOf: { (qualifier, name) in
        binding.resolve(qualifier: qualifier, name: name)
          .map { binding.tables[$0.table].columnCollations[$0.column] }
      },
      columnTypeOf: { (qualifier, name) in
        binding.resolve(qualifier: qualifier, name: name)
          .map { binding.tables[$0.table].columnTypes[$0.column] }
      },
      // Bind-time-resolved slots: read the row directly, no name resolution.
      // Always an inner reference (correlated outer refs stay `.column`).
      boundColumn: { (table, column) throws(DBError) in
        try context.value(table: table, column: column)
      },
      boundCollation: { (table, column) in binding.tables[table].columnCollations[column] },
      boundColumnType: { (table, column) in binding.tables[table].columnTypes[column] },
      scalarSubquery: { sub throws(DBError) in try subquery(sub, context, binding) })
  }

  // MARK: - DISTINCT

  /// First-occurrence dedup under `=` semantics (numeric classes unify, the
  /// same comparison ORDER BY uses) via the canonical `GroupKey` — O(n), the
  /// hashing shared with GROUP BY/UNION (`distinctRows`). `GroupKey`
  /// canonicalization (integral REAL→INTEGER, NOCASE fold) matches the
  /// `orderCompare` equality this used to scan for.
  private static func deduplicate(
    _ rows: [[Value]], sortKeys: [[Value]], ordered: Bool, collations: [Collation]
  ) -> (rows: [[Value]], sortKeys: [[Value]]) {
    var seen = Set<GroupKey>()
    seen.reserveCapacity(rows.count)
    var keptRows: [[Value]] = []
    var keptKeys: [[Value]] = []
    for (index, row) in rows.enumerated()
    where seen.insert(GroupKey(row, collations: collations)).inserted {
      keptRows.append(row)
      if ordered { keptKeys.append(sortKeys[index]) }
    }
    return (keptRows, keptKeys)
  }

  /// True when `orderBy` ranks the leading FTS table's bm25 `rank` slot ascending
  /// (best/most-negative first), optionally followed by the FTS rowid ascending —
  /// i.e. `ORDER BY rank` or `ORDER BY bm25(…), rowid`. This is the only shape
  /// routed to the F6c WAND path: its score-then-smallest-rowid tiebreak matches
  /// the heap's, so WAND returns the identical top-k. Any other ordering (DESC, a
  /// non-rank leading key, a different trailing tiebreak) returns false and keeps
  /// score-all.
  private static func isFTSRankAscendingOrder(_ orderBy: [SQLOrderingTerm]) -> Bool {
    guard let first = orderBy.first, !first.descending,
      case .boundColumn(let table, let column) = first.expr,
      table == 0, column == ftsRankSlot
    else { return false }
    switch orderBy.count {
    case 1:
      return true
    case 2:
      // A trailing rowid-ascending tiebreak (FTS rowid alias is slot 0).
      guard !orderBy[1].descending, case .boundColumn(let t, let c) = orderBy[1].expr else {
        return false
      }
      return t == 0 && c == 0
    default:
      return false
    }
  }

  /// True when `e` (or any sub-expression) reads bound column `(table, column)`.
  /// Used to decide whether an FTS query needs per-doc bm25 scoring (F6e): a
  /// membership-only MATCH never reads the `rank` slot, so scoring is dead work.
  /// A scalar subquery is treated conservatively (assume the score may be read).
  private static func exprReferences(_ e: SQLExpr, table: Int, column: Int) -> Bool {
    switch e {
    case .boundColumn(let t, let c): return t == table && c == column
    case .literal, .column, .parameter, .aggregateResult: return false
    case .binary(_, let l, let r):
      return exprReferences(l, table: table, column: column)
        || exprReferences(r, table: table, column: column)
    case .unary(_, let x), .cast(let x, _), .collate(let x, _):
      return exprReferences(x, table: table, column: column)
    case .like(let x, let p, _):
      return exprReferences(x, table: table, column: column)
        || exprReferences(p, table: table, column: column)
    case .isNull(let x, _):
      return exprReferences(x, table: table, column: column)
    case .inList(let x, let list, _):
      return exprReferences(x, table: table, column: column)
        || list.contains { exprReferences($0, table: table, column: column) }
    case .inJSONEach(let x, let s, _):
      return exprReferences(x, table: table, column: column)
        || exprReferences(s, table: table, column: column)
    case .caseWhen(let op, let whens, let elseExpr):
      if let op, exprReferences(op, table: table, column: column) { return true }
      if whens.contains(where: {
        exprReferences($0.condition, table: table, column: column)
          || exprReferences($0.result, table: table, column: column)
      }) { return true }
      if let elseExpr { return exprReferences(elseExpr, table: table, column: column) }
      return false
    case .function(_, let args, _, _):
      return args.contains { exprReferences($0, table: table, column: column) }
    case .scalarSubquery:
      return true
    }
  }

  // MARK: - ORDER BY

  /// A stable sort permutation: ties (including the pre-sort order) keep input
  /// order so equal rows are deterministic.
  private static func sortedOrder(
    _ keys: [[Value]], terms: [SQLOrderingTerm], collations: [Collation]
  ) -> [Int] {
    keys.indices.sorted { lhs, rhs in
      for position in terms.indices {
        let comparison = orderCompare(keys[lhs][position], keys[rhs][position], collations[position])
        if comparison != 0 {
          return terms[position].descending ? comparison > 0 : comparison < 0
        }
      }
      return lhs < rhs  // stable
    }
  }

  /// ORDER BY / DISTINCT comparison: NULL sorts first (ASC), then SQLite's
  /// cross-class numeric comparison.
  static func orderCompare(_ a: Value, _ b: Value, _ collation: Collation) -> Int {
    switch (a.isNull, b.isNull) {
    case (true, true): return 0
    case (true, false): return -1
    case (false, true): return 1
    case (false, false): return SQLCompare.compare(a, b, collation: collation) ?? 0
    }
  }

  // MARK: - LIMIT / OFFSET

  private static func sliceBounds(
    _ plan: BoundSelect, params: SQLParameters
  ) throws(DBError) -> (offset: Int, limit: Int?)? {
    guard plan.limit != nil || plan.offset != nil else { return nil }
    let env = SQLEvalEnv.parametersOnly { parameter throws(DBError) in try params.lookup(parameter) }

    // Cap each at Int.max/4 so downstream `offset + limit` / `lower + limit`
    // additions can never overflow (Swift `+` traps on overflow). The cap is
    // ~2.3×10^18 — unbounded for any real dataset, so behavior is unchanged.
    let bound = Int.max / 4
    var limit: Int?
    if let limitExpr = plan.limit {
      // SQLite: NULL or negative LIMIT means unbounded.
      if let value = try boundValue(limitExpr, env), value >= 0 {
        limit = min(Int(clamping: value), bound)
      } else {
        limit = nil
      }
    }
    var offset = 0
    if let offsetExpr = plan.offset {
      if let value = try boundValue(offsetExpr, env), value > 0 {
        offset = min(Int(clamping: value), bound)
      }
    }
    return (offset, limit)
  }

  /// Integer coercion for LIMIT/OFFSET (SQLite casts to integer; NULL → nil).
  private static func boundValue(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Int64? {
    switch SQLFunctions.cast(try SQLEval.evaluate(expr, env), to: .integer) {
    case .integer(let value): return value
    default: return nil
    }
  }
}
