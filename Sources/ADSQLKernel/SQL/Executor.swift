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
    _ plan: BoundSelect, table: Catalog.TableRecord, resolver: R, params: SQLParameters
  ) throws(DBError) -> [SQLRow] {
    let slot = RowSlot(table: table.definition)
    let env = rowEnv(plan, slot: slot, params: params)

    var rows: [[Value]] = []
    var sortKeys: [[Value]] = []
    let ordered = !plan.orderBy.isEmpty

    var cursor = try RowCursor(
      resolver: resolver, table: table, mode: .table, lowerKey: nil, upperKey: nil)
    while let (rowid, record) = try cursor.nextRecord() {
      slot.load(rowid: rowid, record: record)
      if let predicate = plan.whereExpr {
        if SQLEval.truth(try SQLEval.evaluate(predicate, env)) != .yes { continue }
      }
      var projected: [Value] = []
      projected.reserveCapacity(plan.outputs.count)
      for output in plan.outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
      rows.append(projected)
      if ordered {
        var keys: [Value] = []
        keys.reserveCapacity(plan.orderBy.count)
        for term in plan.orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
        sortKeys.append(keys)
      }
    }

    if plan.distinct {
      (rows, sortKeys) = deduplicate(
        rows, sortKeys: sortKeys, ordered: ordered, collations: plan.outputCollations)
    }
    if ordered {
      let order = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
      rows = order.map { rows[$0] }
    }

    let bounds = try sliceBounds(plan, params: params)
    if let bounds {
      let lower = min(bounds.offset, rows.count)
      let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
      rows = Array(rows[lower..<upper])
    }
    return rows.map { SQLRow(header: plan.header, values: $0) }
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
