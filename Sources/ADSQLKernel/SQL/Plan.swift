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
  let orderBy: [SQLOrderingTerm]
  let orderCollations: [Collation]
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

enum Binder {
  static func bindSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
    guard select.compounds.isEmpty else {
      throw DBError.sqlUnsupported("UNION/compound SELECT (arrives in a later slice)")
    }
    guard select.groupBy.isEmpty, select.having == nil else {
      throw DBError.sqlUnsupported("GROUP BY / HAVING (arrives in a later slice)")
    }
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
        outputs.append(
          BoundOutput(name: outputName(expr, alias: alias, sourceText: sourceText), expr: expr))
      }
    }

    let orderCollations = select.orderBy.map { collation(of: $0.expr, binding: binding) }
    let outputCollations = outputs.map { collation(of: $0.expr, binding: binding) }
    let header = SQLColumnHeader(outputs.map(\.name))
    // The planner optimizes the outer table only: column-vs-constant conjuncts
    // on it (join predicates are column-vs-column, hence ignored here and left
    // to the residual). For a LEFT join the outer side is never null-extended,
    // so pushing its WHERE conjuncts down stays a valid superset.
    let source = tables[0]
    let planning = Planner.plan(
      where: select.whereExpr, orderBy: select.orderBy, source: source,
      indexes: schema.indexes(on: source.table), definition: schema.tables[source.table]!)
    return BoundSelect(
      binding: binding,
      joins: joins,
      outputs: outputs,
      outputCollations: outputCollations,
      whereExpr: select.whereExpr,
      orderBy: select.orderBy,
      orderCollations: orderCollations,
      distinct: select.distinct,
      limit: select.limit,
      offset: select.offset,
      header: header,
      access: planning.plan,
      accessYieldsOrder: joins.isEmpty && planning.yieldsOrder,
      rowidOrderSatisfiesOrderBy: joins.isEmpty && planning.rowidOrderSatisfiesOrderBy)
  }

  private static func appendAllColumns(_ table: TableBinding, to outputs: inout [BoundOutput]) {
    for name in table.columnNames {
      outputs.append(
        BoundOutput(name: name, expr: .column(table: table.binding, name: name, offset: 0)))
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
