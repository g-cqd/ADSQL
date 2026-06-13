/// Binding turns a parsed `SQLSelect` into a `BoundSelect`: the abstract
/// syntax resolved against a concrete schema version. Binding is the only
/// step that needs the schema, so a `Statement` caches one bound plan per
/// committed catalog version (a DDL commit invalidates it). M4/PR3 binds the
/// single-table shape only — joins, aggregates, and compound selects are
/// rejected here with named `sqlUnsupported` errors and arrive in later
/// slices.

/// One table reference resolved against the schema: the columns in declared
/// order plus a case-insensitive name→index map. The `binding` name is the
/// alias if present, else the table name; qualified column references must
/// match it.
struct TableBinding: Sendable {
  let table: String
  let binding: String           // lowercased alias-or-name for qualifier match
  let columnNames: [String]     // original case, declared order
  let columnTypes: [ColumnType]
  let columnCollations: [Collation]
  let indexByName: [String: Int]  // lowercased name → column index
  let rowidAliasIndex: Int?
  /// True for an FTS5 virtual table reference. Its `definition` is synthetic
  /// (a single `rowid` alias column), so `f.rowid` resolves to slot 0 and a
  /// bare `f` reference is the MATCH subject; the planner produces `.fts` from
  /// the MATCH conjunct rather than from indexes, and the executor drives the
  /// row source through `FTSMatch.evaluate` (no base scan).
  let isFTS: Bool

  init(reference: SQLTableRef, definition: TableDefinition, isFTS: Bool = false) {
    self.table = definition.name
    self.binding = (reference.alias ?? definition.name).lowercased()
    self.columnNames = definition.columns.map(\.name)
    self.columnTypes = definition.columns.map(\.type)
    self.columnCollations = definition.columns.map(\.collation)
    var map: [String: Int] = [:]
    for (index, column) in definition.columns.enumerated() {
      map[column.name.lowercased()] = index
    }
    self.indexByName = map
    self.rowidAliasIndex = definition.rowidAliasIndex
    self.isFTS = isFTS
  }

  func columnIndex(qualifier: String?, name: String) -> Int? {
    if let qualifier, qualifier.lowercased() != binding { return nil }
    return indexByName[name.lowercased()]
  }
}

/// The executor and planner model an FTS5 table as an ordinary rowid-keyed
/// table with two synthetic columns: slot 0 is the `rowid` alias (`RowSlot`
/// returns the docid without touching any record span, so the empty span the
/// `.fts` source supplies is never read; `f.rowid` joins the base table), and
/// slot 1 is `rank` — the bm25 relevance score the `.fts` source computes per
/// matching doc (F4). `f.rank` / bare `rank` resolves to slot 1 and reads the
/// score via `RowSlot.compute`'s `scoreIndex` path, parallel to the rowid path.
/// The `bm25()` index of the rank slot.
let ftsRankSlot = 1

func syntheticFTSDefinition(_ name: String) -> TableDefinition {
  TableDefinition(
    name, columns: [ColumnDefinition("rowid", .integer), ColumnDefinition("rank", .real)],
    primaryKey: .rowidAlias(column: "rowid", autoincrement: false))
}

extension TableDefinition {
  /// The `rank` score-column index for a synthetic FTS definition (the
  /// `[rowid, rank]` shape `syntheticFTSDefinition` builds), else nil. Lets the
  /// executor's `RowSlot` recognize the score slot without a separate flag.
  var ftsScoreIndex: Int? {
    guard columns.count == 2, rowidAliasIndex == 0,
      columns[ftsRankSlot].name == "rank", columns[ftsRankSlot].type == .real
    else { return nil }
    return ftsRankSlot
  }
}

/// A projected output column: its result-set name and the expression that
/// produces it.
struct BoundOutput: Sendable {
  let name: String
  let expr: SQLExpr
}

/// One join in a nested-loop plan: the right-hand table (by index into the
/// query's tables) and its ON predicate. INNER filters matches; LEFT emits one
/// null-extended row when the right side has no match.
struct BoundJoin: Sendable {
  let kind: SQLJoinKind
  let table: Int
  let on: SQLExpr
  /// Index-nested-loop access for this inner table: the index/rowid probe whose
  /// equality values are *outer* expressions (evaluated per outer row). A
  /// superset of the ON-matching rows — ON is still re-applied at the leaf — so
  /// it never changes results, only how many inner rows are touched.
  /// `.tableScan` = full inner scan (no usable equality on an indexed column).
  let access: AccessPlan
}

/// All tables in a query's FROM/JOIN list, with column resolution across them.
struct QueryBinding: Sendable {
  let tables: [TableBinding]

  /// Resolves (qualifier, name) to (table index, column index). Unqualified
  /// names that match more than one table are ambiguous (nil → the evaluator
  /// reports no-such-column).
  func resolve(qualifier: String?, name: String) -> (table: Int, column: Int)? {
    let key = name.lowercased()
    if let qualifier {
      let q = qualifier.lowercased()
      for (index, table) in tables.enumerated() where table.binding == q {
        return table.indexByName[key].map { (index, $0) }
      }
      return nil
    }
    var found: (Int, Int)?
    for (index, table) in tables.enumerated() {
      if let column = table.indexByName[key] {
        if found != nil { return nil }  // ambiguous
        found = (index, column)
      }
    }
    return found
  }
}

/// A SELECT resolved against one schema version: one or more tables (the first
/// is the leading/outer table), joins, projection, filters, and ordering. The
/// access plan optimizes the leading table; joined tables nested-loop scan.
struct BoundSelect: Sendable {
  let binding: QueryBinding
  let joins: [BoundJoin]
  let outputs: [BoundOutput]
  let outputCollations: [Collation]
  let whereExpr: SQLExpr?
  /// WHERE with the conjuncts an exact probe covers removed — used (single
  /// table only) when the executor takes that probe, else `whereExpr`.
  let residualWithoutCovered: SQLExpr?
  let orderBy: [SQLOrderingTerm]
  let orderCollations: [Collation]
  /// GROUP BY key expressions and their collations (empty for a single
  /// implicit group when aggregates appear without GROUP BY).
  let groupBy: [SQLExpr]
  let groupCollations: [Collation]
  /// HAVING, rewritten so aggregate calls are `aggregateResult` slots.
  let having: SQLExpr?
  /// Aggregate slots referenced by the rewritten outputs/having/orderBy.
  let aggregates: [AggregateSpec]
  let isAggregated: Bool
  let distinct: Bool
  let limit: SQLExpr?
  let offset: SQLExpr?
  let header: SQLColumnHeader
  let access: AccessPlan
  /// The access path's natural order satisfies ORDER BY.
  let accessYieldsOrder: Bool
  /// Table (rowid) order satisfies ORDER BY — used on index→scan fallback.
  let rowidOrderSatisfiesOrderBy: Bool

  /// The leading (outer) table — the one the access plan optimizes.
  var source: TableBinding { binding.tables[0] }
  var isJoin: Bool { !joins.isEmpty }
}

/// A prepared query: a single SELECT or a UNION/UNION ALL of SELECT arms.
enum BoundQuery: Sendable {
  case select(BoundSelect)
  case compound(BoundCompound)
}

/// A left-associative compound: arms combined in order (the first arm's op is
/// nil), then a compound-level ORDER BY/LIMIT/OFFSET resolved against the
/// first arm's result columns.
struct BoundCompound: Sendable {
  struct Arm: Sendable {
    let op: SQLCompoundOp?
    let select: BoundSelect
  }
  struct CompoundOrder: Sendable {
    let index: Int          // result-column index
    let descending: Bool
    let collation: Collation
  }
  let arms: [Arm]
  let header: SQLColumnHeader
  let outputCollations: [Collation]
  let order: [CompoundOrder]
  let limit: SQLExpr?
  let offset: SQLExpr?
}

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
    for raw in rawJoins {
      let inner = tables[raw.depth]
      // An FTS inner table has no schema table/indexes; its access comes from a
      // MATCH conjunct on its ON clause, so pass the synthetic definition and no
      // indexes (the planner extracts `.fts` from the MATCH, not from indexes).
      let innerDefinition =
        inner.isFTS ? syntheticFTSDefinition(inner.table) : schema.tables[inner.table]!
      let innerIndexes = inner.isFTS ? [] : schema.indexes(on: inner.table)
      let equalities = joinEqualities(raw.on, binding: binding, innerDepth: raw.depth)
      let access = Planner.planJoin(
        equalities: equalities, inner: inner, on: raw.on, binding: binding, innerDepth: raw.depth,
        indexes: innerIndexes, definition: innerDefinition)
      // A MATCH conjunct the `.fts` access consumes is an access path, never a
      // row predicate, so drop it from the ON clause re-applied during matching
      // (evaluating `.binary(.match,…)` at a row is a runtime error).
      var on = raw.on
      if case .fts = access, let (_, conjunct) = Planner.ftsMatchConjunct(raw.on, source: inner) {
        on = removeCovered(raw.on, [conjunct]) ?? .literal(.integer(1))
      }
      joins.append(BoundJoin(kind: raw.kind, table: raw.depth, on: on, access: access))
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
    let boundJoins = joins.map {
      BoundJoin(kind: $0.kind, table: $0.table, on: bind($0.on), access: $0.access)
    }
    let boundOutputs = outputs.map { BoundOutput(name: $0.name, expr: bind($0.expr)) }
    let boundWhere = whereExpr.map(bind)
    let boundResidual = residualWithoutCovered.map(bind)
    let boundOrderBy = orderBy.map { SQLOrderingTerm(expr: bind($0.expr), descending: $0.descending) }
    let boundGroupBy = select.groupBy.map(bind)
    let boundHaving = having.map(bind)
    // Apply the captured weights now that every expression has been bound (so a
    // bm25() anywhere in the projection/ORDER BY is seen). Default to all-ones
    // for a plain `rank` reference (the table index is the leading table or the
    // join depth).
    return BoundSelect(
      binding: binding,
      joins: boundJoins.map {
        BoundJoin(
          kind: $0.kind, table: $0.table, on: $0.on,
          access: bindAccess(applyWeights($0.access, ftsWeights, depth: $0.table), binding))
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
      aggregates: aggregates.map { bindAggregate($0, binding) },
      isAggregated: isAggregated,
      distinct: select.distinct,
      limit: select.limit,
      offset: select.offset,
      header: header,
      access: bindAccess(applyWeights(planning.plan, ftsWeights, depth: 0), binding),
      accessYieldsOrder: yieldsOrder && planning.yieldsOrder,
      rowidOrderSatisfiesOrderBy: yieldsOrder && planning.rowidOrderSatisfiesOrderBy)
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
  ) -> [(column: Int, value: SQLExpr)] {
    func conj(_ e: SQLExpr) -> [SQLExpr] {
      if case .binary(.and, let l, let r) = e { return conj(l) + conj(r) }
      return [e]
    }
    var out: [(column: Int, value: SQLExpr)] = []
    for clause in conj(on) {
      guard case .binary(.eq, let lhs, let rhs) = clause else { continue }
      if let column = innerColumn(lhs, binding: binding, depth: innerDepth),
        referencesOnlyBelow(rhs, depth: innerDepth, binding: binding)
      {
        out.append((column, rhs))
      } else if let column = innerColumn(rhs, binding: binding, depth: innerDepth),
        referencesOnlyBelow(lhs, depth: innerDepth, binding: binding)
      {
        out.append((column, lhs))
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
