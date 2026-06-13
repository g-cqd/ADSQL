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
final class RowSlot {
  private let columns: [ColumnDefinition]
  private let aliasIndex: Int?
  private(set) var rowid: Int64 = 0
  private var span = UnsafeRawBufferPointer(start: nil, count: 0)
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
    self.cache = Array(repeating: nil, count: table.columns.count)
    self.offsets = []
    self.offsets.reserveCapacity(table.columns.count)
  }

  /// Re-points the slot at a new row's record span; resets the decode state.
  /// The span must stay valid for as long as the slot is read (the scan driver
  /// guarantees this within the per-row body).
  func load(rowid: Int64, span: UnsafeRawBufferPointer) {
    self.rowid = rowid
    self.span = span
    self.headerParsed = false
    self.locatedCount = 0
    self.offsets.removeAll(keepingCapacity: true)
    for index in cache.indices { cache[index] = nil }
  }

  func value(at index: Int) throws(DBError) -> Value {
    if let cached = cache[index] { return cached }
    let value = try compute(at: index)
    cache[index] = value
    return value
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
    guard let start = try locate(index) else {
      switch columns[index].defaultValue {
      case .value(let value): return value
      case .datetimeNow, nil: return .null
      }
    }
    return try RecordCodec.decodeCell(span, at: start)
  }

  /// Byte start of stored cell `index`, or nil if beyond the stored count.
  /// Walks (and records) only as far as `index`, reusing prior work.
  private func locate(_ index: Int) throws(DBError) -> Int? {
    if !headerParsed {
      var offset = 0
      storedCount = try RecordCodec.readHeader(span, &offset)
      scanOffset = offset
      headerParsed = true
    }
    if index >= storedCount { return nil }
    while locatedCount <= index {
      offsets.append(scanOffset)
      try RecordCodec.skipCell(span, &scanOffset)
      locatedCount += 1
    }
    return offsets[index]
  }
}

enum SelectExecutor {
  static func run<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)? = nil,
    subquery: @escaping SubqueryRunner = rejectSubquery
  ) throws(DBError) -> [SQLRow] {
    if plan.isAggregated {
      return try runAggregated(
        plan, tables: tables, index: index, resolver: resolver, params: params,
        outer: outer, subquery: subquery)
    }
    if plan.isJoin {
      return try runJoin(
        plan, tables: tables, index: index, resolver: resolver, params: params,
        outer: outer, subquery: subquery)
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
    let source = try resolveSource(plan, table: table, index: index, env: paramsEnv)
    let ordered: Bool
    switch source {
    case .table:
      ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
    case .rowids:
      ordered = plan.accessYieldsOrder
    case .index(_, let list):
      ordered = plan.orderBy.isEmpty || (plan.accessYieldsOrder && list.count <= 1)
    }

    // Early-exit under LIMIT is sound only when the source order is final and
    // no later DISTINCT can drop earlier rows.
    let collectKeys = !ordered && !plan.orderBy.isEmpty
    let sliceEnd: Int? =
      (ordered && !plan.distinct && bounds?.limit != nil)
      ? (bounds!.offset + bounds!.limit!) : nil
    // Bounded top-N: an unordered ORDER BY + (small) LIMIT without DISTINCT
    // keeps only offset+limit rows instead of materializing and sorting every
    // match. Larger limits fall back to collect-and-sort.
    let topN: Int? = {
      guard collectKeys, !plan.distinct, let limit = bounds?.limit, limit >= 1 else { return nil }
      let bound = bounds!.offset + limit
      return bound >= 1 && bound <= 4096 ? bound : nil
    }()
    let dedupRowids: Bool = {
      if case .index(_, let list) = source { return list.count > 1 }
      return false
    }()

    // A taken rowid/index probe exactly covers its equality conjuncts, so the
    // residual can drop them; a table scan (incl. the coercion fallback) must
    // re-check the full WHERE.
    let residual: SQLExpr?
    switch source {
    case .table: residual = plan.whereExpr
    case .rowids, .index: residual = plan.residualWithoutCovered
    }
    let accumulator = Accumulator(
      context: context, env: env, residual: residual, outputs: plan.outputs,
      orderBy: plan.orderBy, orderCollations: plan.orderCollations, collectKeys: collectKeys,
      sliceEnd: sliceEnd, topN: topN, dedupRowids: dedupRowids)
    try forEachRow(source, table: table, resolver: resolver) { rowid, span throws(DBError) in
      try accumulator.consume(rowid: rowid, span: span)
    }

    var rows = accumulator.rows
    var sortKeys = accumulator.sortKeys
    if plan.distinct {
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

  // MARK: - Row sources

  private enum RowSource {
    case table
    case rowids([Int64])
    case index(Catalog.IndexRecord, [IndexBounds])
  }

  /// Accumulates surviving rows; `consume` returns false to request early
  /// termination (LIMIT reached on an already-ordered source).
  private final class Accumulator {
    let context: RowContext
    let env: SQLEvalEnv
    let residual: SQLExpr?
    let outputs: [BoundOutput]
    let orderBy: [SQLOrderingTerm]
    let orderCollations: [Collation]
    let collectKeys: Bool
    let sliceEnd: Int?
    /// Bounded top-N capacity (offset+limit) for an unordered ORDER BY + LIMIT
    /// without DISTINCT. When set, `rows`/`sortKeys` are kept sorted ascending
    /// and capped, so unkept rows are never projected and the full sort is
    /// avoided. nil = collect everything (the caller sorts).
    let topN: Int?
    var seenRowids: Set<Int64>?
    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []

    var presorted: Bool { topN != nil }

    init(
      context: RowContext, env: SQLEvalEnv, residual: SQLExpr?, outputs: [BoundOutput],
      orderBy: [SQLOrderingTerm], orderCollations: [Collation], collectKeys: Bool,
      sliceEnd: Int?, topN: Int?, dedupRowids: Bool
    ) {
      self.context = context
      self.env = env
      self.residual = residual
      self.outputs = outputs
      self.orderBy = orderBy
      self.orderCollations = orderCollations
      self.collectKeys = collectKeys
      self.sliceEnd = sliceEnd
      self.topN = topN
      self.seenRowids = dedupRowids ? [] : nil
    }

    func consume(rowid: Int64, span: UnsafeRawBufferPointer) throws(DBError) -> Bool {
      if seenRowids != nil {
        if seenRowids!.contains(rowid) { return true }
        seenRowids!.insert(rowid)
      }
      context.load(0, rowid: rowid, span: span)
      if let residual {
        if SQLEval.truth(try SQLEval.evaluate(residual, env)) != .yes { return true }
      }

      if let topN {
        // Compute the sort key first; only project rows that make the cut.
        var keys: [Value] = []
        keys.reserveCapacity(orderBy.count)
        for term in orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        if rows.count >= topN, !orderBefore(keys, sortKeys[topN - 1]) { return true }
        insertSorted(keys, try project())
        return true
      }

      rows.append(try project())
      if collectKeys {
        var keys: [Value] = []
        keys.reserveCapacity(orderBy.count)
        for term in orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        sortKeys.append(keys)
      }
      if let sliceEnd, rows.count >= sliceEnd { return false }
      return true
    }

    private func project() throws(DBError) -> [Value] {
      var projected: [Value] = []
      projected.reserveCapacity(outputs.count)
      for output in outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
      return projected
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

  /// Drives a row source, invoking `body` per `(rowid, recordSpan)`. The span
  /// is a zero-copy view into the mapped page, valid only for the duration of
  /// the `body` call; `body` returns false to stop early.
  private static func forEachRow<R: PageResolver>(
    _ source: RowSource, table: Catalog.TableRecord, resolver: R,
    _ body: (Int64, UnsafeRawBufferPointer) throws(DBError) -> Bool
  ) throws(DBError) {
    switch source {
    case .table:
      var cursor = try RowCursor(
        resolver: resolver, table: table, mode: .table, lowerKey: nil, upperKey: nil)
      try cursor.forEachRecordSpan(body)
    case .rowids(let rowids):
      for rowid in rowids {
        let outcome: Bool? = try Relation.withRowValue(
          resolver, table.handle, key: KeyCodec.rowKey(rowid)
        ) { ref throws(DBError) in
          try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
            try body(rowid, span)
          }
        }
        if outcome == false { return }  // nil = no such row → skip
      }
    case .index(let index, let boundsList):
      for bounds in boundsList {
        let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
        var cursor = try RowCursor(
          resolver: resolver, table: table, mode: .index(index), lowerKey: lower, upperKey: upper)
        try cursor.forEachRecordSpan(body)
      }
    }
  }

  /// Resolves the leading table's access plan into a concrete row source for
  /// this execution (probe values may be parameters; an unconvertible probe
  /// falls back to a table scan).
  private static func resolveSource(
    _ plan: BoundSelect, table: Catalog.TableRecord, index: Catalog.IndexRecord?,
    env paramsEnv: SQLEvalEnv
  ) throws(DBError) -> RowSource {
    switch plan.access {
    case .tableScan:
      return .table
    case .rowid(let exprs):
      return .rowids(try evaluateRowids(exprs, paramsEnv))
    case .index(_, let probes, _):
      guard let index else { return .table }
      switch try buildIndexBounds(probes, index: index, table: table, env: paramsEnv) {
      case .scan: return .table
      case .bounds(let list): return .index(index, list)
      }
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
    resolver: R, context: RowContext, env: SQLEvalEnv, paramsEnv: SQLEvalEnv,
    _ body: () throws(DBError) -> Void
  ) throws(DBError) {
    func passesWhere() throws(DBError) -> Bool {
      guard let predicate = plan.whereExpr else { return true }
      return SQLEval.truth(try SQLEval.evaluate(predicate, env)) == .yes
    }

    guard plan.isJoin else {
      let source = try resolveSource(plan, table: tables[0], index: index, env: paramsEnv)
      try forEachRow(source, table: tables[0], resolver: resolver) {
        rowid, span throws(DBError) in
        context.load(0, rowid: rowid, span: span)
        if try passesWhere() { try body() }
        return true
      }
      return
    }

    func descend(_ depth: Int) throws(DBError) {
      if depth == tables.count {
        if try passesWhere() { try body() }
        return
      }
      let join = plan.joins[depth - 1]
      var matched = false
      try forEachRow(.table, table: tables[depth], resolver: resolver) {
        rowid, span throws(DBError) in
        context.load(depth, rowid: rowid, span: span)
        if SQLEval.truth(try SQLEval.evaluate(join.on, env)) == .yes {
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

    let outerSource = try resolveSource(plan, table: tables[0], index: index, env: paramsEnv)
    try forEachRow(outerSource, table: tables[0], resolver: resolver) {
      rowid, span throws(DBError) in
      context.load(0, rowid: rowid, span: span)
      try descend(1)
      return true
    }
  }

  private static func runJoin<R: PageResolver>(
    _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner
  ) throws(DBError) -> [SQLRow] {
    let context = RowContext(definitions: tables.map(\.definition))
    let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let collectKeys = !plan.orderBy.isEmpty

    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []
    try forEachFilteredRow(
      plan, tables: tables, index: index, resolver: resolver,
      context: context, env: env, paramsEnv: paramsEnv
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
    resolver: R, params: SQLParameters,
    outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner
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
      plan, tables: tables, index: index, resolver: resolver,
      context: context, env: scanEnv, paramsEnv: paramsEnv
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
          representative.append(
            context.nullExtended[table]
              ? Array(repeating: Value.null, count: columnCounts[table])
              : try context.slots[table].materialize())
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
      var offset = 0
      if let offsetExpr = compound.offset, let value = try boundValue(offsetExpr, env), value > 0 {
        offset = Int(clamping: value)
      }
      var limit: Int?
      if let limitExpr = compound.limit, let value = try boundValue(limitExpr, env), value >= 0 {
        limit = Int(clamping: value)
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

    func load(_ table: Int, rowid: Int64, span: UnsafeRawBufferPointer) {
      nullExtended[table] = false
      slots[table].load(rowid: rowid, span: span)
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
      scalarSubquery: { sub throws(DBError) in try subquery(sub, context, binding) })
  }

  // MARK: - DISTINCT

  /// First-occurrence dedup under `=` semantics (numeric classes unify, the
  /// same comparison ORDER BY uses). Quadratic; small result sets only. PR5
  /// replaces this with canonical-key hashing shared with GROUP BY/UNION.
  private static func deduplicate(
    _ rows: [[Value]], sortKeys: [[Value]], ordered: Bool, collations: [Collation]
  ) -> (rows: [[Value]], sortKeys: [[Value]]) {
    var keptRows: [[Value]] = []
    var keptKeys: [[Value]] = []
    for (index, row) in rows.enumerated() {
      let seen = keptRows.contains { existing in
        guard existing.count == row.count else { return false }
        for column in row.indices where orderCompare(existing[column], row[column], collations[column]) != 0 {
          return false
        }
        return true
      }
      if seen { continue }
      keptRows.append(row)
      if ordered { keptKeys.append(sortKeys[index]) }
    }
    return (keptRows, keptKeys)
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

    var limit: Int?
    if let limitExpr = plan.limit {
      // SQLite: NULL or negative LIMIT means unbounded.
      if let value = try boundValue(limitExpr, env), value >= 0 {
        limit = Int(clamping: value)
      } else {
        limit = nil
      }
    }
    var offset = 0
    if let offsetExpr = plan.offset {
      if let value = try boundValue(offsetExpr, env), value > 0 {
        offset = Int(clamping: value)
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
