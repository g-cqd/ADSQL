/// SQL write execution over a `WriteTxn`: INSERT/UPDATE/DELETE plus DDL. Each
/// reuses the M3 relational engine (strict typing, conflict policies, index
/// maintenance, FK actions) and the SQL evaluator for VALUES/SET/WHERE/
/// RETURNING expressions. UPDATE and DELETE are two-phase (collect matching
/// rowids, then mutate) to avoid mutating a tree under its own cursor.
enum Writer {
  static func execute(
    _ ast: SQLStatementAST, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    switch ast {
    case .insert(let insert):
      return try self.insert(insert, txn: txn, params: params)
    case .update, .delete, .createTable, .createIndex, .dropTable, .dropIndex:
      throw DBError.sqlUnsupported("this write statement arrives in a later slice")
    case .select, .begin, .commit, .rollback:
      throw DBError.sqlUnsupported("not a write statement")
    }
  }

  // MARK: - INSERT

  static func insert(
    _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    let schema = try txn.schema()
    guard let definition = schema.tables[insert.table] else {
      throw DBError.noSuchTable(insert.table)
    }
    let conflict: ConflictPolicy
    switch insert.conflict {
    case .abort: conflict = .abort
    case .replace: conflict = .replace
    case .ignore: conflict = .ignore
    case .doUpdate:
      throw DBError.sqlUnsupported("INSERT ... ON CONFLICT DO UPDATE (upsert)")
    }

    let columnNames = insert.columns.isEmpty ? definition.columns.map(\.name) : insert.columns
    for name in columnNames where definition.columnIndex(of: name) == nil {
      throw DBError.noSuchColumn(table: insert.table, column: name)
    }

    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let returning = try bindReturning(insert.returning, definition: definition)
    let header = returning.map { SQLColumnHeader($0.map(\.name)) }
    var returningRows: [SQLRow] = []
    var changes = 0
    var lastRowid: Int64 = 0

    for rowExprs in insert.rows {
      guard rowExprs.count == columnNames.count else {
        throw DBError.sqlBind(
          "\(rowExprs.count) values for \(columnNames.count) columns in INSERT")
      }
      var values: [String: Value] = [:]
      for (index, expr) in rowExprs.enumerated() {
        values[columnNames[index]] = try SQLEval.evaluate(expr, paramsEnv)
      }
      guard let rowid = try txn.insert(into: insert.table, values, onConflict: conflict) else {
        continue  // OR IGNORE skipped a conflicting row
      }
      changes += 1
      lastRowid = rowid
      if let returning, let header {
        returningRows.append(
          try project(returning, table: definition, rowid: rowid, txn: txn, header: header, params: params))
      }
    }
    return (returningRows, RunResult(changes: changes, lastInsertRowid: lastRowid))
  }

  // MARK: - RETURNING

  /// Resolves RETURNING columns to (name, expression), expanding `*`.
  static func bindReturning(
    _ columns: [SQLResultColumn], definition: TableDefinition
  ) throws(DBError) -> [(name: String, expr: SQLExpr)]? {
    guard !columns.isEmpty else { return nil }
    var outputs: [(name: String, expr: SQLExpr)] = []
    for column in columns {
      switch column {
      case .star, .tableStar:
        for name in definition.columns.map(\.name) {
          outputs.append((name, .column(table: nil, name: name, offset: 0)))
        }
      case .expr(let expr, let alias, let sourceText):
        let name: String
        if let alias {
          name = alias
        } else if case .column(_, let columnName, _) = expr {
          name = columnName
        } else {
          name = sourceText
        }
        outputs.append((name, expr))
      }
    }
    return outputs
  }

  /// Reads a row back and evaluates the RETURNING expressions against it.
  static func project(
    _ returning: [(name: String, expr: SQLExpr)], table: TableDefinition, rowid: Int64,
    txn: borrowing WriteTxn, header: SQLColumnHeader, params: SQLParameters
  ) throws(DBError) -> SQLRow {
    guard let row = try txn.row(in: table.name, rowid: rowid) else {
      throw DBError.integrityFailure("RETURNING row \(rowid) vanished")
    }
    let env = rowEnv(table: table, values: row.values, params: params)
    var values: [Value] = []
    values.reserveCapacity(returning.count)
    for output in returning { values.append(try SQLEval.evaluate(output.expr, env)) }
    return SQLRow(header: header, values: values)
  }

  /// An evaluation env over one materialized row of a single table.
  static func rowEnv(
    table: TableDefinition, values: [Value], params: SQLParameters
  ) -> SQLEvalEnv {
    SQLEvalEnv(
      parameter: { p throws(DBError) in try params.lookup(p) },
      column: { (qualifier, name, _) throws(DBError) in
        guard let index = table.columnIndex(of: name) else {
          throw DBError.noSuchColumn(table: qualifier ?? table.name, column: name)
        }
        return values[index]
      },
      collationOf: { (_, name) in table.columnIndex(of: name).map { table.columns[$0].collation } },
      columnTypeOf: { (_, name) in table.columnIndex(of: name).map { table.columns[$0].type } },
      scalarSubquery: { _ throws(DBError) in
        throw DBError.sqlUnsupported("subquery in this context")
      })
  }
}
