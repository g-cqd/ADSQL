/// The binder: turns a parsed `SQLSelect` into a `BoundSelect`/`BoundQuery`
/// (the abstract syntax resolved against a concrete schema version), including
/// access selection, join-equality analysis, aggregate rewriting, and column
/// binding. The bound-plan data types it produces live in `Plan.swift`.
enum Binder {
  /// Binds a top-level query: a single SELECT or a compound. The trailing
  /// ORDER BY/LIMIT/OFFSET on a compound belong to the whole result, so the
  /// first arm is bound without them.
  static func bindQuery(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundQuery {
    guard !select.compounds.isEmpty else {
      return .select(try bindSelect(select, schema: schema))
    }
    var firstArm = select
    firstArm.compounds = []
    firstArm.orderBy = []
    firstArm.limit = nil
    firstArm.offset = nil
    var arms: [BoundCompound.Arm] = [
      BoundCompound.Arm(op: nil, select: try bindSelect(firstArm, schema: schema))
    ]
    for compound in select.compounds {
      arms.append(
        BoundCompound.Arm(op: compound.op, select: try bindSelect(compound.select, schema: schema)))
    }
    let width = arms[0].select.outputs.count
    for arm in arms where arm.select.outputs.count != width {
      throw DBError.sqlBind("SELECTs to the left and right of a compound have different column counts")
    }
    let first = arms[0].select
    var order: [BoundCompound.CompoundOrder] = []
    for term in select.orderBy {
      order.append(
        try resolveCompoundOrder(term, outputs: first.outputs, collations: first.outputCollations))
    }
    return .compound(
      BoundCompound(
        arms: arms, header: first.header, outputCollations: first.outputCollations,
        order: order, limit: select.limit, offset: select.offset))
  }

  /// A compound ORDER BY term references a result column by 1-based position
  /// or by name (SQLite restriction).
  private static func resolveCompoundOrder(
    _ term: SQLOrderingTerm, outputs: [BoundOutput], collations: [Collation]
  ) throws(DBError) -> BoundCompound.CompoundOrder {
    var expr = term.expr
    var explicit: Collation?
    if case .collate(let inner, let collation) = expr {
      expr = inner
      explicit = collation
    }
    let index: Int
    switch expr {
    case .literal(.integer(let position)):
      guard position >= 1, position <= outputs.count else {
        throw DBError.sqlBind("ORDER BY position \(position) is out of range")
      }
      index = Int(position) - 1
    case .column(nil, let name, _):
      guard let match = outputs.firstIndex(where: { $0.name.lowercased() == name.lowercased() })
      else {
        throw DBError.sqlBind("ORDER BY \(name) is not a column of the compound result")
      }
      index = match
    default:
      throw DBError.sqlUnsupported("compound ORDER BY must name a result column or position")
    }
    return BoundCompound.CompoundOrder(
      index: index, descending: term.descending, collation: explicit ?? collations[index])
  }

  static func bindSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
    guard let from = select.from else {
      throw DBError.sqlUnsupported("SELECT without FROM (arrives in a later slice)")
    }

    // Resolve every table in FROM/JOIN order; the first is the outer table. An
    // FTS5 virtual table isn't in `schema.tables`; it binds against a synthetic
    // rowid-alias definition (its only queryable column is `rowid`; the indexed
    // text is reached through MATCH, not column reads).
    func bind(_ reference: SQLTableRef) throws(DBError) -> TableBinding {
      if let definition = schema.tables[reference.name] {
        return TableBinding(reference: reference, definition: definition)
      }
      if schema.ftsTables[reference.name] != nil {
        return TableBinding(
          reference: reference, definition: syntheticFTSDefinition(reference.name), isFTS: true)
      }
      throw DBError.noSuchTable(reference.name)
    }
    var tables: [TableBinding] = [try bind(from)]
    var rawJoins: [(kind: SQLJoinKind, depth: Int, on: SQLExpr)] = []
    for join in select.joins {
      tables.append(try bind(join.table))
      rawJoins.append((join.kind, tables.count - 1, join.on))
    }
    let binding = QueryBinding(tables: tables)

    // Index-nested-loop access per inner table: each ON conjunct of the form
    // `inner.col = <expr over outer tables>` is a *necessary* match condition,
    // so probing it is a valid superset (ON is re-applied at the leaf). Falls
    // back to a full inner scan when no such equality hits an indexed column.
    var joins: [BoundJoin] = []
    // Whether each join's access is an exact-equality probe that covers its
    // *entire* ON predicate — the bind-time half of the existence-only test
    // (completed in the final pass once column references are known).
    var joinProbeCoversON: [Bool] = []
    for raw in rawJoins {
      let inner = tables[raw.depth]
      // An FTS inner table has no schema table/indexes; its access comes from a
      // MATCH conjunct on its ON clause, so pass the synthetic definition and no
      // indexes (the planner extracts `.fts` from the MATCH, not from indexes).
      let innerDefinition =
        inner.isFTS ? syntheticFTSDefinition(inner.table) : schema.tables[inner.table]!
      let innerIndexes = inner.isFTS ? [] : schema.indexes(on: inner.table)
      let equalities = joinEqualities(raw.on, binding: binding, innerDepth: raw.depth)
      let (access, covered) = Planner.planJoin(
        equalities: equalities, inner: inner, on: raw.on, binding: binding, innerDepth: raw.depth,
        indexes: innerIndexes, definition: innerDefinition)
      // A MATCH conjunct the `.fts` access consumes is an access path, never a
      // row predicate, so drop it from the ON clause re-applied during matching
      // (evaluating `.binary(.match,…)` at a row is a runtime error).
      var on = raw.on
      if case .fts = access, let (_, conjunct) = Planner.ftsMatchConjunct(raw.on, source: inner) {
        on = removeCovered(raw.on, [conjunct]) ?? .literal(.integer(1))
      }
      // An exact-equality probe (`.rowid`, or `.index` with no trailing range)
      // whose covered conjuncts are the whole ON means the probe alone enforces
      // the join — the executor can skip the ON re-check (and, if the inner is
      // otherwise unreferenced, the table descent entirely).
      joinProbeCoversON.append(isExactEquality(access) && removeCovered(raw.on, covered) == nil)
      joins.append(
        BoundJoin(kind: raw.kind, table: raw.depth, on: on, access: access, innerExistenceOnly: false))
    }

    // Aggregate calls in outputs/HAVING/ORDER BY are rewritten to slot
    // references; `aggregates` collects the distinct ones to accumulate.
    var aggregates: [AggregateSpec] = []
    var outputs: [BoundOutput] = []
    for column in select.columns {
      switch column {
      case .star:
        for table in tables { appendAllColumns(table, to: &outputs) }
      case .tableStar(let qualifier):
        guard let table = tables.first(where: { $0.binding == qualifier.lowercased() }) else {
          throw DBError.sqlBind("no such table alias: \(qualifier)")
        }
        appendAllColumns(table, to: &outputs)
      case .expr(let expr, let alias, let sourceText):
        let rewritten = try rewriteAggregates(expr, into: &aggregates)
        outputs.append(
          BoundOutput(name: outputName(expr, alias: alias, sourceText: sourceText), expr: rewritten))
      }
    }
    var having: SQLExpr?
    if let rawHaving = select.having {
      having = try rewriteAggregates(rawHaving, into: &aggregates)
    }
    // ORDER BY resolves a bare identifier against output aliases first (SQLite
    // behavior), so `... score*2 AS s ORDER BY s` sorts by the expression.
    var orderBy = select.orderBy
    for index in orderBy.indices {
      if case .column(nil, let name, _) = orderBy[index].expr,
        let match = outputs.first(where: { $0.name.lowercased() == name.lowercased() })
      {
        orderBy[index].expr = match.expr  // already aggregate-rewritten
      } else {
        orderBy[index].expr = try rewriteAggregates(orderBy[index].expr, into: &aggregates)
      }
    }
    let isAggregated = !select.groupBy.isEmpty || !aggregates.isEmpty

    let orderCollations = orderBy.map { collation(of: $0.expr, binding: binding) }
    let outputCollations = outputs.map { collation(of: $0.expr, binding: binding) }
    let groupCollations = select.groupBy.map { collation(of: $0, binding: binding) }
    let header = SQLColumnHeader(outputs.map(\.name))
    // The planner optimizes the outer table only: column-vs-constant conjuncts
    // on it (join predicates are column-vs-column, hence ignored here and left
    // to the residual). For a LEFT join the outer side is never null-extended,
    // so pushing its WHERE conjuncts down stays a valid superset. Aggregated
    // queries scan every row, so the planner's order claims don't apply.
    let source = tables[0]
    // A leading FTS table has no schema table/indexes; its access is the `.fts`
    // path the planner extracts from a `f MATCH '…'` WHERE conjunct (synthetic
    // definition, no indexes — MATCH drives the source, columns don't).
    let sourceDefinition =
      source.isFTS ? syntheticFTSDefinition(source.table) : schema.tables[source.table]!
    let sourceIndexes = source.isFTS ? [] : schema.indexes(on: source.table)
    let planning = Planner.plan(
      where: select.whereExpr, orderBy: select.orderBy, source: source,
      indexes: sourceIndexes, definition: sourceDefinition)
    let yieldsOrder = joins.isEmpty && !isAggregated
    // A leading-FTS MATCH conjunct is an access path the `.fts` source consumes,
    // never a row predicate — strip it from the base WHERE used as the leaf
    // residual on *every* path (join/aggregate included), or evaluating
    // `.binary(.match,…)` per row would be a runtime error.
    var whereExpr = select.whereExpr
    if case .fts = planning.plan {
      whereExpr = removeCovered(whereExpr, planning.coveredConjuncts)
    }
    // Residual elimination applies to the single-table path only (the join/
    // aggregate paths evaluate the full WHERE at the leaf).
    let residualWithoutCovered =
      yieldsOrder
      ? removeCovered(whereExpr, planning.coveredConjuncts)
      : whereExpr

    // Final step: resolve every runtime column reference to (table, column)
    // slots so the evaluator never re-resolves names per row. Runs after all
    // bind-time analysis (planning, collation, INLJ extraction, removeCovered),
    // which consumed the `.column` form. Correlated outer refs that don't
    // resolve here stay `.column` (runtime outer fallback).
    //
    // The same pass intercepts `bm25(tbl, w0, w1, …)` (and bare `rank`), which
    // reads the FTS `rank` score slot: it rewrites the call to a bound read of
    // that slot and records the per-column weights for the table, so they can be
    // threaded into the `.fts` access plan below (one ranking per FTS table).
    var ftsWeights: [Int: [Double]] = [:]
    func bind(_ expr: SQLExpr) -> SQLExpr { bindColumns(expr, binding, &ftsWeights) }
    let boundOutputs = outputs.map { BoundOutput(name: $0.name, expr: bind($0.expr)) }
    let boundWhere = whereExpr.map(bind)
    let boundResidual = residualWithoutCovered.map(bind)
    let boundOrderBy = orderBy.map { SQLOrderingTerm(expr: bind($0.expr), descending: $0.descending) }
    let boundGroupBy = select.groupBy.map(bind)
    let boundHaving = having.map(bind)
    let boundAggregates = aggregates.map { bindAggregate($0, binding) }
    let boundJoinsOn = joins.map { bind($0.on) }
    let mergePlan = mergeJoinPlan(joins: joins, boundOn: boundJoinsOn, binding: binding, schema: schema)
    // Apply the captured weights now that every expression has been bound (so a
    // bm25() anywhere in the projection/ORDER BY is seen). Default to all-ones
    // for a plain `rank` reference (the table index is the leading table or the
    // join depth).
    let leadingAccess = bindAccess(applyWeights(planning.plan, ftsWeights, depth: 0), binding)
    let boundJoinAccess = joins.map {
      bindAccess(applyWeights($0.access, ftsWeights, depth: $0.table), binding)
    }

    // Column-reference analysis (drives the existence-only join inner and the
    // aggregate materialization guard). `alwaysRefs` are tables whose real row
    // bytes are read during the scan (projection / WHERE / HAVING / ORDER BY /
    // GROUP BY / aggregates / any access-path probe value). An unresolved
    // `.column` (correlated) or a scalar subquery sets `unknownRefs`, which
    // conservatively disables every elision.
    var alwaysRefs: Set<Int> = []
    var unknownRefs = false
    for o in boundOutputs { collectTableRefs(o.expr, into: &alwaysRefs, unknown: &unknownRefs) }
    if let w = boundWhere { collectTableRefs(w, into: &alwaysRefs, unknown: &unknownRefs) }
    if let h = boundHaving { collectTableRefs(h, into: &alwaysRefs, unknown: &unknownRefs) }
    for t in boundOrderBy { collectTableRefs(t.expr, into: &alwaysRefs, unknown: &unknownRefs) }
    for g in boundGroupBy { collectTableRefs(g, into: &alwaysRefs, unknown: &unknownRefs) }
    for spec in boundAggregates {
      switch spec.kind {
      case .countStar: break
      case .count(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
      case .sum(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
      }
    }
    collectAccessRefs(leadingAccess, into: &alwaysRefs, unknown: &unknownRefs)
    for acc in boundJoinAccess { collectAccessRefs(acc, into: &alwaysRefs, unknown: &unknownRefs) }
    // Per-join ON references; a join other than d may read d's columns.
    var onRefs: [Set<Int>] = []
    for on in boundJoinsOn {
      var refs: Set<Int> = []
      collectTableRefs(on, into: &refs, unknown: &unknownRefs)
      onRefs.append(refs)
    }
    // Existence-only iff the probe covers the whole ON (bind-time) AND no other
    // expression — including any *other* join's ON — reads this inner table.
    let existenceOnly: [Bool] = joins.indices.map { d in
      guard !unknownRefs, joinProbeCoversON[d] else { return false }
      let table = joins[d].table
      if alwaysRefs.contains(table) { return false }
      for e in joins.indices where e != d && onRefs[e].contains(table) { return false }
      return true
    }
    // Tables whose group representative is read at finalization (outputs /
    // HAVING / ORDER BY). Existence-only tables are guaranteed absent.
    var finalRefs: Set<Int> = []
    var finalUnknown = false
    for o in boundOutputs { collectTableRefs(o.expr, into: &finalRefs, unknown: &finalUnknown) }
    if let h = boundHaving { collectTableRefs(h, into: &finalRefs, unknown: &finalUnknown) }
    for t in boundOrderBy { collectTableRefs(t.expr, into: &finalRefs, unknown: &finalUnknown) }
    let finalizationReferenced: Set<Int> =
      finalUnknown ? Set(tables.indices) : finalRefs

    // Index-ordered DISTINCT: a single-table `SELECT DISTINCT <plain cols>` with
    // no WHERE/ORDER BY/aggregate can scan an index whose key columns are exactly
    // those outputs, decoding each distinct key prefix — no table descent, no
    // dedup set. Excludes NOCASE-text columns (case is folded into the key, so it
    // can't reconstruct the original value); those fall back to streaming dedup.
    var distinctIndexName: String?
    if select.distinct, !isAggregated, joins.isEmpty, !source.isFTS,
      select.whereExpr == nil, select.orderBy.isEmpty
    {
      var columnNames: [String] = []
      var eligible = true
      for out in outputs {
        guard case .column(let qualifier, let name, _) = out.expr,
          let column = source.columnIndex(qualifier: qualifier, name: name)
        else { eligible = false; break }
        if source.columnTypes[column] == .text, source.columnCollations[column] == .nocase {
          eligible = false  // NOCASE text decodes to folded bytes, not the original
          break
        }
        columnNames.append(name)
      }
      if eligible, !columnNames.isEmpty {
        for candidate in sourceIndexes
        where candidate.columns.count == columnNames.count
          && zip(candidate.columns, columnNames).allSatisfy({
            $0.lowercased() == $1.lowercased()
          })
        {
          distinctIndexName = candidate.name
          break
        }
      }
    }

    return BoundSelect(
      binding: binding,
      joins: joins.indices.map { d in
        BoundJoin(
          kind: joins[d].kind, table: joins[d].table, on: boundJoinsOn[d],
          access: boundJoinAccess[d], innerExistenceOnly: existenceOnly[d])
      },
      outputs: boundOutputs,
      outputCollations: outputCollations,
      whereExpr: boundWhere,
      residualWithoutCovered: boundResidual,
      orderBy: boundOrderBy,
      orderCollations: orderCollations,
      groupBy: boundGroupBy,
      groupCollations: groupCollations,
      having: boundHaving,
      aggregates: boundAggregates,
      isAggregated: isAggregated,
      distinct: select.distinct,
      limit: select.limit,
      offset: select.offset,
      header: header,
      access: leadingAccess,
      accessYieldsOrder: yieldsOrder && planning.yieldsOrder,
      rowidOrderSatisfiesOrderBy: yieldsOrder && planning.rowidOrderSatisfiesOrderBy,
      finalizationReferencedTables: finalizationReferenced,
      distinctIndexName: distinctIndexName,
      mergePlan: mergePlan)
  }

  /// A 2-table INNER equi-join whose join-key columns each have a UNIQUE,
  /// NOT-NULL, single-column index of the same collation → merge-eligible (the
  /// executor lock-steps the two sorted indexes under `.merge`/`.auto`). nil
  /// otherwise (the proven nested-loop / hash paths handle every other shape).
  private static func mergeJoinPlan(
    joins: [BoundJoin], boundOn: [SQLExpr], binding: QueryBinding, schema: Schema
  ) -> MergePlan? {
    guard joins.count == 1, joins[0].kind == .inner, binding.tables.count == 2,
      !binding.tables[0].isFTS, !binding.tables[1].isFTS,
      case .binary(.eq, let lhs, let rhs) = boundOn[0]
    else { return nil }
    func cols(_ a: SQLExpr, _ b: SQLExpr) -> (outer: Int, inner: Int)? {
      guard case .boundColumn(let at, let ac) = a, case .boundColumn(let bt, let bc) = b,
        at == 0, bt == 1
      else { return nil }
      return (ac, bc)
    }
    guard let (oc, ic) = cols(lhs, rhs) ?? cols(rhs, lhs),
      binding.tables[0].columnCollations[oc] == binding.tables[1].columnCollations[ic],
      let outerIndex = uniqueKeyIndex(binding.tables[0], column: oc, schema: schema),
      let innerIndex = uniqueKeyIndex(binding.tables[1], column: ic, schema: schema)
    else { return nil }
    return MergePlan(
      outerIndex: outerIndex, innerIndex: innerIndex, outerColumn: oc, innerColumn: ic)
  }

  /// The name of a UNIQUE, single-column index on `column` of `table` whose
  /// column is NOT NULL (so no NULL keys break the merge lock-step), else nil.
  private static func uniqueKeyIndex(
    _ table: TableBinding, column: Int, schema: Schema
  ) -> String? {
    guard let definition = schema.tables[table.table], column < definition.columns.count,
      definition.columns[column].notNull
    else { return nil }
    let columnName = table.columnNames[column].lowercased()
    for index in schema.indexes(on: table.table)
    where index.unique && index.columns.count == 1
      && index.columns[0].lowercased() == columnName {
      return index.name
    }
    return nil
  }

  /// Adds the `(table)` of every `.boundColumn` in `expr` to `refs`. Sets
  /// `unknown` for an unresolved/correlated `.column` or a scalar subquery, whose
  /// reachable columns can't be determined here (callers then disable the
  /// reference-driven elisions). Covers every `SQLExpr` case.
  private static func collectTableRefs(
    _ expr: SQLExpr, into refs: inout Set<Int>, unknown: inout Bool
  ) {
    switch expr {
    case .boundColumn(let table, _):
      refs.insert(table)
    case .column, .scalarSubquery:
      unknown = true
    case .literal, .parameter, .aggregateResult:
      break
    case .binary(_, let l, let r):
      collectTableRefs(l, into: &refs, unknown: &unknown)
      collectTableRefs(r, into: &refs, unknown: &unknown)
    case .unary(_, let i), .cast(let i, _), .collate(let i, _):
      collectTableRefs(i, into: &refs, unknown: &unknown)
    case .isNull(let i, _):
      collectTableRefs(i, into: &refs, unknown: &unknown)
    case .like(let s, let p, _):
      collectTableRefs(s, into: &refs, unknown: &unknown)
      collectTableRefs(p, into: &refs, unknown: &unknown)
    case .inList(let s, let items, _):
      collectTableRefs(s, into: &refs, unknown: &unknown)
      for item in items { collectTableRefs(item, into: &refs, unknown: &unknown) }
    case .inJSONEach(let s, let src, _):
      collectTableRefs(s, into: &refs, unknown: &unknown)
      collectTableRefs(src, into: &refs, unknown: &unknown)
    case .caseWhen(let operand, let whens, let elseExpr):
      if let operand { collectTableRefs(operand, into: &refs, unknown: &unknown) }
      for when in whens {
        collectTableRefs(when.condition, into: &refs, unknown: &unknown)
        collectTableRefs(when.result, into: &refs, unknown: &unknown)
      }
      if let elseExpr { collectTableRefs(elseExpr, into: &refs, unknown: &unknown) }
    case .function(_, let args, _, _):
      for arg in args { collectTableRefs(arg, into: &refs, unknown: &unknown) }
    }
  }

  /// Adds the tables referenced by an access path's probe/rowid/MATCH value
  /// expressions (evaluated per outer row for a join inner).
  private static func collectAccessRefs(
    _ access: AccessPlan, into refs: inout Set<Int>, unknown: inout Bool
  ) {
    switch access {
    case .tableScan:
      break
    case .rowid(let exprs):
      for e in exprs { collectTableRefs(e, into: &refs, unknown: &unknown) }
    case .index(_, let probes, _):
      for probe in probes {
        for e in probe.equality { collectTableRefs(e, into: &refs, unknown: &unknown) }
        if case .range(let lower, let upper)? = probe.trailing {
          if let lower { collectTableRefs(lower.expr, into: &refs, unknown: &unknown) }
          if let upper { collectTableRefs(upper.expr, into: &refs, unknown: &unknown) }
        }
      }
    case .fts(_, let query, _):
      collectTableRefs(query, into: &refs, unknown: &unknown)
    }
  }

  /// An exact-equality probe — every matching row satisfies the covered ON
  /// equality exactly (no trailing range to re-check). `.tableScan`/`.fts` are
  /// supersets, so never exact.
  private static func isExactEquality(_ access: AccessPlan) -> Bool {
    switch access {
    case .rowid:
      return true
    case .index(_, let probes, _):
      return !probes.isEmpty && probes.allSatisfy { $0.trailing == nil }
    case .tableScan, .fts:
      return false
    }
  }

  /// Overlays captured bm25() weights onto an `.fts` access plan for the table at
  /// `depth`; other plans pass through. With no bm25() call the plan keeps the
  /// Planner's default (empty → all-ones at execution), i.e. plain `rank`.
  private static func applyWeights(
    _ access: AccessPlan, _ weights: [Int: [Double]], depth: Int
  ) -> AccessPlan {
    guard case .fts(let table, let query, _) = access, let captured = weights[depth] else {
      return access
    }
    return .fts(table: table, query: query, weights: captured)
  }

  /// Resolves resolvable `.column` refs to `.boundColumn(table, column)` slots
  /// (leaving correlated outer refs as `.column`); does not descend into
  /// `.scalarSubquery` (bound independently when executed). A `bm25(tbl, …)`
  /// call is rewritten to a bound read of the table's `rank` score slot, with its
  /// weight literals captured into `weights` (keyed by the table's depth).
  private static func bindColumns(
    _ expr: SQLExpr, _ binding: QueryBinding, _ weights: inout [Int: [Double]]
  ) -> SQLExpr {
    switch expr {
    case .column(let qualifier, let name, _):
      if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
        return .boundColumn(table: table, column: column)
      }
      return expr
    case .literal, .parameter, .aggregateResult, .boundColumn, .scalarSubquery:
      return expr
    case .binary(let op, let lhs, let rhs):
      return .binary(op, bindColumns(lhs, binding, &weights), bindColumns(rhs, binding, &weights))
    case .unary(let op, let inner):
      return .unary(op, bindColumns(inner, binding, &weights))
    case .like(let subject, let pattern, let negated):
      return .like(
        bindColumns(subject, binding, &weights),
        pattern: bindColumns(pattern, binding, &weights), negated: negated)
    case .isNull(let inner, let negated):
      return .isNull(bindColumns(inner, binding, &weights), negated: negated)
    case .inList(let subject, let items, let negated):
      return .inList(
        bindColumns(subject, binding, &weights),
        items.map { bindColumns($0, binding, &weights) }, negated: negated)
    case .inJSONEach(let subject, let source, let negated):
      return .inJSONEach(
        bindColumns(subject, binding, &weights),
        source: bindColumns(source, binding, &weights), negated: negated)
    case .caseWhen(let operand, let whens, let elseExpr):
      return .caseWhen(
        operand: operand.map { bindColumns($0, binding, &weights) },
        whens: whens.map {
          SQLWhen(
            condition: bindColumns($0.condition, binding, &weights),
            result: bindColumns($0.result, binding, &weights))
        },
        elseExpr: elseExpr.map { bindColumns($0, binding, &weights) })
    case .function(let name, let args, let star, let offset):
      if name.uppercased() == "BM25", let bound = bindBM25(args, binding, &weights) {
        return bound
      }
      return .function(
        name: name, args: args.map { bindColumns($0, binding, &weights) }, star: star,
        offset: offset)
    case .cast(let inner, let type):
      return .cast(bindColumns(inner, binding, &weights), type)
    case .collate(let inner, let collation):
      return .collate(bindColumns(inner, binding, &weights), collation)
    }
  }

  /// Binds `bm25(tbl, w0, w1, …)`: the first argument names the FTS table (its
  /// alias-or-name, parsed as a bare column ref), the rest are numeric weight
  /// literals. Returns a bound read of the table's `rank` slot and records the
  /// authored weights under the table's depth (the executor pads/truncates them
  /// to the real column count); nil if the first argument doesn't name an FTS
  /// table in this query (so the generic `.function` path reports the error).
  private static func bindBM25(
    _ args: [SQLExpr], _ binding: QueryBinding, _ weights: inout [Int: [Double]]
  ) -> SQLExpr? {
    guard let first = args.first, case .column(let qualifier, let name, _) = first else { return nil }
    let target = qualifier ?? name
    guard let depth = binding.tables.firstIndex(where: { $0.binding == target.lowercased() }),
      binding.tables[depth].isFTS
    else { return nil }
    // Capture the authored weights as written; missing args default to 1.0 and
    // the real per-column length is resolved at execution (the synthetic binding
    // only carries [rowid, rank], not the FTS table's real text columns).
    weights[depth] = args.dropFirst().map { numericLiteral($0) ?? 1.0 }
    return .boundColumn(table: depth, column: ftsRankSlot)
  }

  /// A numeric weight literal (integer or real); nil otherwise.
  private static func numericLiteral(_ expr: SQLExpr) -> Double? {
    switch expr {
    case .literal(.integer(let value)): return Double(value)
    case .literal(.real(let value)): return value
    case .unary(.negate, let inner): return numericLiteral(inner).map { -$0 }
    default: return nil
    }
  }

  private static func bindAccess(_ access: AccessPlan, _ binding: QueryBinding) -> AccessPlan {
    switch access {
    case .tableScan:
      return .tableScan
    case .rowid(let exprs):
      return .rowid(exprs.map { bindColumnsNoWeights($0, binding) })
    case .index(let name, let probes, let constraint):
      let bound = probes.map { probe in
        IndexProbe(
          equality: probe.equality.map { bindColumnsNoWeights($0, binding) },
          trailing: probe.trailing.map { bindTrailing($0, binding) })
      }
      return .index(name: name, probes: bound, constraint: constraint)
    case .fts(let table, let query, let weights):
      // The query string is a literal/parameter; bind it like any expression
      // (a stray column ref would just stay `.column` and fail at evaluation).
      // The weights were already captured/applied from any bm25() call.
      return .fts(table: table, query: bindColumnsNoWeights(query, binding), weights: weights)
    }
  }

  /// `bindColumns` for the access-path expressions (probe values, MATCH query):
  /// these never contain a bm25() call, so the weight collector is discarded.
  private static func bindColumnsNoWeights(_ expr: SQLExpr, _ binding: QueryBinding) -> SQLExpr {
    var weights: [Int: [Double]] = [:]
    return bindColumns(expr, binding, &weights)
  }

  private static func bindTrailing(_ trailing: Trailing, _ binding: QueryBinding) -> Trailing {
    switch trailing {
    case .range(let lower, let upper):
      func bound(_ b: BoundExpr) -> BoundExpr {
        BoundExpr(expr: bindColumnsNoWeights(b.expr, binding), inclusive: b.inclusive)
      }
      return .range(lower: lower.map(bound), upper: upper.map(bound))
    }
  }

  private static func bindAggregate(_ spec: AggregateSpec, _ binding: QueryBinding) -> AggregateSpec {
    switch spec.kind {
    case .countStar: return spec
    case .count(let expr): return AggregateSpec(kind: .count(bindColumnsNoWeights(expr, binding)))
    case .sum(let expr): return AggregateSpec(kind: .sum(bindColumnsNoWeights(expr, binding)))
    }
  }

  /// WHERE with `covered` top-level conjuncts removed (nil if none remain).
  /// The covered nodes are the exact AST nodes the planner consumed, so `==`
  /// matches them.
  private static func removeCovered(_ expr: SQLExpr?, _ covered: [SQLExpr]) -> SQLExpr? {
    guard let expr, !covered.isEmpty else { return expr }
    func conjuncts(_ e: SQLExpr) -> [SQLExpr] {
      if case .binary(.and, let lhs, let rhs) = e { return conjuncts(lhs) + conjuncts(rhs) }
      return [e]
    }
    let kept = conjuncts(expr).filter { conjunct in !covered.contains { $0 == conjunct } }
    guard let first = kept.first else { return nil }
    return kept.dropFirst().reduce(first) { .binary(.and, $0, $1) }
  }

  /// Equalities `inner.col = <outer expr>` from a join's ON, binding-aware: the
  /// column side must resolve (in the full query binding) to the inner table at
  /// `innerDepth`, and the value side must reference only strictly-earlier
  /// tables (evaluable per outer row). Each is a necessary match condition.
  private static func joinEqualities(
    _ on: SQLExpr, binding: QueryBinding, innerDepth: Int
  ) -> [(column: Int, value: SQLExpr, source: SQLExpr)] {
    func conj(_ e: SQLExpr) -> [SQLExpr] {
      if case .binary(.and, let l, let r) = e { return conj(l) + conj(r) }
      return [e]
    }
    var out: [(column: Int, value: SQLExpr, source: SQLExpr)] = []
    for clause in conj(on) {
      guard case .binary(.eq, let lhs, let rhs) = clause else { continue }
      if let column = innerColumn(lhs, binding: binding, depth: innerDepth),
        referencesOnlyBelow(rhs, depth: innerDepth, binding: binding)
      {
        out.append((column, rhs, clause))
      } else if let column = innerColumn(rhs, binding: binding, depth: innerDepth),
        referencesOnlyBelow(lhs, depth: innerDepth, binding: binding)
      {
        out.append((column, lhs, clause))
      }
    }
    return out
  }

  private static func innerColumn(
    _ expr: SQLExpr, binding: QueryBinding, depth: Int
  ) -> Int? {
    guard case .column(let qualifier, let name, _) = expr,
      let (table, column) = binding.resolve(qualifier: qualifier, name: name), table == depth
    else { return nil }
    return column
  }

  /// Every column reference resolves to a table strictly before `depth` (and no
  /// subqueries/aggregates); literals and parameters are stable.
  private static func referencesOnlyBelow(
    _ expr: SQLExpr, depth: Int, binding: QueryBinding
  ) -> Bool {
    func below(_ e: SQLExpr) -> Bool { referencesOnlyBelow(e, depth: depth, binding: binding) }
    switch expr {
    case .literal, .parameter:
      return true
    case .column(let qualifier, let name, _):
      guard let (table, _) = binding.resolve(qualifier: qualifier, name: name) else { return false }
      return table < depth
    case .boundColumn(let table, _):
      return table < depth
    case .scalarSubquery, .inJSONEach, .aggregateResult:
      return false
    case .collate(let inner, _), .cast(let inner, _), .unary(_, let inner):
      return below(inner)
    case .isNull(let inner, _):
      return below(inner)
    case .binary(_, let lhs, let rhs):
      return below(lhs) && below(rhs)
    case .like(let subject, let pattern, _):
      return below(subject) && below(pattern)
    case .inList(let subject, let items, _):
      return below(subject) && items.allSatisfy(below)
    case .caseWhen(let operand, let whens, let elseExpr):
      return (operand.map(below) ?? true)
        && whens.allSatisfy { below($0.condition) && below($0.result) }
        && (elseExpr.map(below) ?? true)
    case .function(_, let args, _, _):
      return args.allSatisfy(below)
    }
  }

  private static func appendAllColumns(_ table: TableBinding, to outputs: inout [BoundOutput]) {
    for name in table.columnNames {
      outputs.append(
        BoundOutput(name: name, expr: .column(table: table.binding, name: name, offset: 0)))
    }
  }

  private static let aggregateNames: Set<String> = [
    "COUNT", "SUM", "AVG", "MIN", "MAX", "TOTAL", "GROUP_CONCAT",
  ]

  /// Replaces aggregate calls with `aggregateResult(slot)` references,
  /// collecting the distinct specs. Recurses through scalar expressions (so
  /// `COALESCE(SUM(x), 0)` works) but leaves subqueries — a different scope —
  /// untouched.
  private static func rewriteAggregates(
    _ expr: SQLExpr, into aggregates: inout [AggregateSpec]
  ) throws(DBError) -> SQLExpr {
    func slot(_ spec: AggregateSpec) -> SQLExpr {
      if let existing = aggregates.firstIndex(of: spec) { return .aggregateResult(existing) }
      aggregates.append(spec)
      return .aggregateResult(aggregates.count - 1)
    }
    switch expr {
    case .literal, .column, .boundColumn, .parameter, .scalarSubquery, .aggregateResult:
      return expr
    case .function(let name, let args, let star, let offset):
      let upper = name.uppercased()
      if aggregateNames.contains(upper) {
        switch upper {
        case "COUNT":
          if star { return slot(AggregateSpec(kind: .countStar)) }
          guard args.count == 1 else {
            throw DBError.sqlUnsupported("COUNT expects one argument or *")
          }
          return slot(AggregateSpec(kind: .count(args[0])))
        case "SUM":
          guard !star, args.count == 1 else { throw DBError.sqlUnsupported("SUM(expr)") }
          return slot(AggregateSpec(kind: .sum(args[0])))
        default:
          throw DBError.sqlUnsupported("aggregate \(upper) (only COUNT and SUM in this slice)")
        }
      }
      var rewritten: [SQLExpr] = []
      for arg in args { rewritten.append(try rewriteAggregates(arg, into: &aggregates)) }
      return .function(name: name, args: rewritten, star: star, offset: offset)
    case .binary(let op, let lhs, let rhs):
      return .binary(
        op, try rewriteAggregates(lhs, into: &aggregates),
        try rewriteAggregates(rhs, into: &aggregates))
    case .unary(let op, let inner):
      return .unary(op, try rewriteAggregates(inner, into: &aggregates))
    case .like(let subject, let pattern, let negated):
      return .like(
        try rewriteAggregates(subject, into: &aggregates),
        pattern: try rewriteAggregates(pattern, into: &aggregates), negated: negated)
    case .isNull(let inner, let negated):
      return .isNull(try rewriteAggregates(inner, into: &aggregates), negated: negated)
    case .inList(let subject, let items, let negated):
      var rewritten: [SQLExpr] = []
      for item in items { rewritten.append(try rewriteAggregates(item, into: &aggregates)) }
      return .inList(
        try rewriteAggregates(subject, into: &aggregates), rewritten, negated: negated)
    case .inJSONEach(let subject, let source, let negated):
      return .inJSONEach(
        try rewriteAggregates(subject, into: &aggregates),
        source: try rewriteAggregates(source, into: &aggregates), negated: negated)
    case .caseWhen(let operand, let whens, let elseExpr):
      var newOperand: SQLExpr?
      if let operand { newOperand = try rewriteAggregates(operand, into: &aggregates) }
      var newWhens: [SQLWhen] = []
      for when in whens {
        newWhens.append(
          SQLWhen(
            condition: try rewriteAggregates(when.condition, into: &aggregates),
            result: try rewriteAggregates(when.result, into: &aggregates)))
      }
      var newElse: SQLExpr?
      if let elseExpr { newElse = try rewriteAggregates(elseExpr, into: &aggregates) }
      return .caseWhen(operand: newOperand, whens: newWhens, elseExpr: newElse)
    case .cast(let inner, let type):
      return .cast(try rewriteAggregates(inner, into: &aggregates), type)
    case .collate(let inner, let collation):
      return .collate(try rewriteAggregates(inner, into: &aggregates), collation)
    }
  }

  /// SQLite result-column naming: an explicit alias wins; an unaliased column
  /// reference takes the column's name; everything else uses its source text.
  private static func outputName(_ expr: SQLExpr, alias: String?, sourceText: String) -> String {
    if let alias { return alias }
    if case .column(_, let name, _) = expr { return name }
    return sourceText
  }

  /// Collation of an expression for ORDER BY / DISTINCT: explicit COLLATE
  /// wins, else the referenced column's declared collation, else BINARY.
  private static func collation(of expr: SQLExpr, binding: QueryBinding) -> Collation {
    switch expr {
    case .collate(_, let collation):
      return collation
    case .column(let qualifier, let name, _):
      if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
        return binding.tables[table].columnCollations[column]
      }
      return .binary
    default:
      return .binary
    }
  }
}
