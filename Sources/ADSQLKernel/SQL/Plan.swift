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

  init(reference: SQLTableRef, definition: TableDefinition) {
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
  }

  func columnIndex(qualifier: String?, name: String) -> Int? {
    if let qualifier, qualifier.lowercased() != binding { return nil }
    return indexByName[name.lowercased()]
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

    // Resolve every table in FROM/JOIN order; the first is the outer table.
    func bind(_ reference: SQLTableRef) throws(DBError) -> TableBinding {
      guard let definition = schema.tables[reference.name] else {
        throw DBError.noSuchTable(reference.name)
      }
      return TableBinding(reference: reference, definition: definition)
    }
    var tables: [TableBinding] = [try bind(from)]
    var joins: [BoundJoin] = []
    for join in select.joins {
      tables.append(try bind(join.table))
      joins.append(BoundJoin(kind: join.kind, table: tables.count - 1, on: join.on))
    }
    let binding = QueryBinding(tables: tables)

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
    let planning = Planner.plan(
      where: select.whereExpr, orderBy: select.orderBy, source: source,
      indexes: schema.indexes(on: source.table), definition: schema.tables[source.table]!)
    let yieldsOrder = joins.isEmpty && !isAggregated
    // Residual elimination applies to the single-table path only (the join/
    // aggregate paths evaluate the full WHERE at the leaf).
    let residualWithoutCovered =
      yieldsOrder
      ? removeCovered(select.whereExpr, planning.coveredConjuncts)
      : select.whereExpr
    return BoundSelect(
      binding: binding,
      joins: joins,
      outputs: outputs,
      outputCollations: outputCollations,
      whereExpr: select.whereExpr,
      residualWithoutCovered: residualWithoutCovered,
      orderBy: orderBy,
      orderCollations: orderCollations,
      groupBy: select.groupBy,
      groupCollations: groupCollations,
      having: having,
      aggregates: aggregates,
      isAggregated: isAggregated,
      distinct: select.distinct,
      limit: select.limit,
      offset: select.offset,
      header: header,
      access: planning.plan,
      accessYieldsOrder: yieldsOrder && planning.yieldsOrder,
      rowidOrderSatisfiesOrderBy: yieldsOrder && planning.rowidOrderSatisfiesOrderBy)
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
    case .literal, .column, .parameter, .scalarSubquery, .aggregateResult:
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
