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

/// A single-table SELECT resolved against one schema version.
struct BoundSelect: Sendable {
  let source: TableBinding
  let outputs: [BoundOutput]
  let outputCollations: [Collation]
  let whereExpr: SQLExpr?
  let orderBy: [SQLOrderingTerm]
  let orderCollations: [Collation]
  let distinct: Bool
  let limit: SQLExpr?
  let offset: SQLExpr?
  let header: SQLColumnHeader
}

enum Binder {
  static func bindSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
    guard select.joins.isEmpty else {
      throw DBError.sqlUnsupported("JOIN (arrives in a later slice)")
    }
    guard select.compounds.isEmpty else {
      throw DBError.sqlUnsupported("UNION/compound SELECT (arrives in a later slice)")
    }
    guard select.groupBy.isEmpty, select.having == nil else {
      throw DBError.sqlUnsupported("GROUP BY / HAVING (arrives in a later slice)")
    }
    guard let from = select.from else {
      throw DBError.sqlUnsupported("SELECT without FROM (arrives in a later slice)")
    }
    guard let definition = schema.tables[from.name] else {
      throw DBError.noSuchTable(from.name)
    }
    let source = TableBinding(reference: from, definition: definition)

    var outputs: [BoundOutput] = []
    for column in select.columns {
      switch column {
      case .star:
        appendAllColumns(source, to: &outputs)
      case .tableStar(let qualifier):
        guard qualifier.lowercased() == source.binding else {
          throw DBError.sqlBind("no such table alias: \(qualifier)")
        }
        appendAllColumns(source, to: &outputs)
      case .expr(let expr, let alias, let sourceText):
        outputs.append(
          BoundOutput(name: outputName(expr, alias: alias, sourceText: sourceText), expr: expr))
      }
    }

    let orderCollations = select.orderBy.map { collation(of: $0.expr, source: source) }
    let outputCollations = outputs.map { collation(of: $0.expr, source: source) }
    let header = SQLColumnHeader(outputs.map(\.name))
    return BoundSelect(
      source: source,
      outputs: outputs,
      outputCollations: outputCollations,
      whereExpr: select.whereExpr,
      orderBy: select.orderBy,
      orderCollations: orderCollations,
      distinct: select.distinct,
      limit: select.limit,
      offset: select.offset,
      header: header)
  }

  private static func appendAllColumns(_ source: TableBinding, to outputs: inout [BoundOutput]) {
    for name in source.columnNames {
      outputs.append(
        BoundOutput(name: name, expr: .column(table: nil, name: name, offset: 0)))
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
  private static func collation(of expr: SQLExpr, source: TableBinding) -> Collation {
    switch expr {
    case .collate(_, let collation):
      return collation
    case .column(let qualifier, let name, _):
      if let index = source.columnIndex(qualifier: qualifier, name: name) {
        return source.columnCollations[index]
      }
      return .binary
    default:
      return .binary
    }
  }
}
