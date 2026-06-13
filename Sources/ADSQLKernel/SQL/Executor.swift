/// Single-table SELECT execution over a `PageResolver` (committed reader or
/// write-transaction overlay). The pipeline is full scan → WHERE filter →
/// projection → DISTINCT → ORDER BY → OFFSET/LIMIT, fully materialized before
/// the transaction closure returns. Access-path selection (rowid/index
/// probes, ordered early-exit) arrives in M4/PR4; here every query is a scan.

/// On-demand row view over copied record bytes. Decodes a column only when
/// the evaluator asks for it and caches the result, so a scan that filters on
/// one column never pays to materialize the rest of a rejected row. The
/// rowid-alias column reads back from the rowid, and columns beyond the
/// stored count fall to their schema default (mirroring
/// `Relation.materializeRow`).
final class RowSlot {
  private let columns: [ColumnDefinition]
  private let aliasIndex: Int?
  private(set) var rowid: Int64 = 0
  private var record: [UInt8] = []
  private var offsets: [Int]?
  private var cache: [Value?]

  init(table: TableDefinition) {
    self.columns = table.columns
    self.aliasIndex = table.rowidAliasIndex
    self.cache = Array(repeating: nil, count: table.columns.count)
  }

  /// Re-points the slot at a new row; clears the per-column decode cache.
  func load(rowid: Int64, record: [UInt8]) {
    self.rowid = rowid
    self.record = record
    self.offsets = nil
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
    let offsets = try ensureOffsets()
    guard index < offsets.count else {
      switch columns[index].defaultValue {
      case .value(let value): return value
      case .datetimeNow, nil: return .null
      }
    }
    let start = offsets[index]
    var result: Result<Value, DBError> = .success(.null)
    record.withUnsafeBytes { raw in
      do throws(DBError) {
        result = .success(try RecordCodec.decodeCell(raw, at: start))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  private func ensureOffsets() throws(DBError) -> [Int] {
    if let offsets { return offsets }
    var result: Result<[Int], DBError> = .success([])
    record.withUnsafeBytes { raw in
      do throws(DBError) {
        result = .success(try RecordCodec.cellOffsets(raw))
      } catch {
        result = .failure(error)
      }
    }
    let computed = try result.get()
    offsets = computed
    return computed
  }
}

enum SelectExecutor {
  static func run<R: PageResolver>(
    _ plan: BoundSelect, table: Catalog.TableRecord, index: Catalog.IndexRecord?,
    resolver: R, params: SQLParameters
  ) throws(DBError) -> [SQLRow] {
    let slot = RowSlot(table: table.definition)
    let env = rowEnv(plan, slot: slot, params: params)
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let bounds = try sliceBounds(plan, params: params)

    // Resolve the access path into a concrete row source, then decide whether
    // its order satisfies ORDER BY (so the sort and a LIMIT early-exit are
    // safe). An index probe whose values do not convert to the column class
    // falls back to a table scan — still correct via the residual WHERE.
    let source: RowSource
    let ordered: Bool
    switch plan.access {
    case .tableScan:
      source = .table
      ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
    case .rowid(let exprs):
      source = .rowids(try evaluateRowids(exprs, paramsEnv))
      ordered = plan.accessYieldsOrder
    case .index(_, let probes, _):
      guard let index else {
        source = .table
        ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
        break
      }
      switch try buildIndexBounds(probes, index: index, table: table, env: paramsEnv) {
      case .scan:
        source = .table
        ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
      case .bounds(let list):
        source = .index(index, list)
        ordered = plan.orderBy.isEmpty || (plan.accessYieldsOrder && list.count <= 1)
      }
    }

    // Early-exit under LIMIT is sound only when the source order is final and
    // no later DISTINCT can drop earlier rows.
    let collectKeys = !ordered && !plan.orderBy.isEmpty
    let sliceEnd: Int? =
      (ordered && !plan.distinct && bounds?.limit != nil)
      ? (bounds!.offset + bounds!.limit!) : nil
    let dedupRowids: Bool = {
      if case .index(_, let list) = source { return list.count > 1 }
      return false
    }()

    let accumulator = Accumulator(
      slot: slot, env: env, residual: plan.whereExpr, outputs: plan.outputs,
      orderBy: plan.orderBy, collectKeys: collectKeys, sliceEnd: sliceEnd,
      dedupRowids: dedupRowids)
    try scan(source, table: table, resolver: resolver, into: accumulator)

    var rows = accumulator.rows
    var sortKeys = accumulator.sortKeys
    if plan.distinct {
      (rows, sortKeys) = deduplicate(
        rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
    }
    if collectKeys {
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
    let slot: RowSlot
    let env: SQLEvalEnv
    let residual: SQLExpr?
    let outputs: [BoundOutput]
    let orderBy: [SQLOrderingTerm]
    let collectKeys: Bool
    let sliceEnd: Int?
    var seenRowids: Set<Int64>?
    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []

    init(
      slot: RowSlot, env: SQLEvalEnv, residual: SQLExpr?, outputs: [BoundOutput],
      orderBy: [SQLOrderingTerm], collectKeys: Bool, sliceEnd: Int?, dedupRowids: Bool
    ) {
      self.slot = slot
      self.env = env
      self.residual = residual
      self.outputs = outputs
      self.orderBy = orderBy
      self.collectKeys = collectKeys
      self.sliceEnd = sliceEnd
      self.seenRowids = dedupRowids ? [] : nil
    }

    func consume(rowid: Int64, record: [UInt8]) throws(DBError) -> Bool {
      if seenRowids != nil {
        if seenRowids!.contains(rowid) { return true }
        seenRowids!.insert(rowid)
      }
      slot.load(rowid: rowid, record: record)
      if let residual {
        if SQLEval.truth(try SQLEval.evaluate(residual, env)) != .yes { return true }
      }
      var projected: [Value] = []
      projected.reserveCapacity(outputs.count)
      for output in outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
      rows.append(projected)
      if collectKeys {
        var keys: [Value] = []
        keys.reserveCapacity(orderBy.count)
        for term in orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        sortKeys.append(keys)
      }
      if let sliceEnd, rows.count >= sliceEnd { return false }
      return true
    }
  }

  private static func scan<R: PageResolver>(
    _ source: RowSource, table: Catalog.TableRecord, resolver: R, into acc: Accumulator
  ) throws(DBError) {
    switch source {
    case .table:
      var cursor = try RowCursor(
        resolver: resolver, table: table, mode: .table, lowerKey: nil, upperKey: nil)
      while let (rowid, record) = try cursor.nextRecord() {
        if !(try acc.consume(rowid: rowid, record: record)) { return }
      }
    case .rowids(let rowids):
      for rowid in rowids {
        guard
          let record = try Relation.getBytes(resolver, table.handle, key: KeyCodec.rowKey(rowid))
        else { continue }
        if !(try acc.consume(rowid: rowid, record: record)) { return }
      }
    case .index(let index, let boundsList):
      for bounds in boundsList {
        let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
        var cursor = try RowCursor(
          resolver: resolver, table: table, mode: .index(index), lowerKey: lower, upperKey: upper)
        while let (rowid, record) = try cursor.nextRecord() {
          if !(try acc.consume(rowid: rowid, record: record)) { return }
        }
      }
    }
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

  // MARK: - Evaluation environment

  private static func rowEnv(
    _ plan: BoundSelect, slot: RowSlot, params: SQLParameters
  ) -> SQLEvalEnv {
    let source = plan.source
    return SQLEvalEnv(
      parameter: { parameter throws(DBError) in try params.lookup(parameter) },
      column: { (qualifier, name, _) throws(DBError) in
        guard let index = source.columnIndex(qualifier: qualifier, name: name) else {
          throw DBError.noSuchColumn(table: qualifier ?? source.table, column: name)
        }
        return try slot.value(at: index)
      },
      collationOf: { (qualifier, name) in
        source.columnIndex(qualifier: qualifier, name: name).map { source.columnCollations[$0] }
      },
      columnTypeOf: { (qualifier, name) in
        source.columnIndex(qualifier: qualifier, name: name).map { source.columnTypes[$0] }
      },
      scalarSubquery: { _ throws(DBError) in
        throw DBError.sqlUnsupported("subquery (arrives in a later slice)")
      })
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
