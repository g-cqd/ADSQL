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
    case .update(let update):
      return try self.update(update, txn: txn, params: params)
    case .delete(let delete):
      return try self.delete(delete, txn: txn, params: params)
    case .createTable(let create):
      try createTable(create, txn: txn)
      return ([], RunResult())
    case .createVirtualTable(let create):
      try createVirtualTable(create, txn: txn)
      return ([], RunResult())
    case .createIndex(let create):
      try createIndex(create, txn: txn)
      return ([], RunResult())
    case .dropTable(let name, let ifExists):
      try dropTable(name, ifExists: ifExists, txn: txn)
      return ([], RunResult())
    case .dropIndex(let name, let ifExists):
      try dropIndex(name, ifExists: ifExists, txn: txn)
      return ([], RunResult())
    case .select, .pragma, .begin, .commit, .rollback:
      throw DBError.sqlUnsupported("not a write statement")
    }
  }

  // MARK: - DDL

  static func createTable(_ create: SQLCreateTable, txn: borrowing WriteTxn) throws(DBError) {
    let schema = try txn.schema()
    if schema.tables[create.definition.name] != nil || schema.ftsTables[create.definition.name] != nil {
      if create.ifNotExists { return }
      throw DBError.invalidDefinition("table \(create.definition.name) already exists")
    }
    try txn.createTable(create.definition)
    for index in create.impliedIndexes { try txn.createIndex(index) }
  }

  static func createVirtualTable(
    _ create: SQLCreateVirtualTable, txn: borrowing WriteTxn
  ) throws(DBError) {
    let schema = try txn.schema()
    if schema.tables[create.definition.name] != nil || schema.ftsTables[create.definition.name] != nil {
      if create.ifNotExists { return }
      throw DBError.invalidDefinition("table \(create.definition.name) already exists")
    }
    try txn.createVirtualTable(create.definition)
  }

  static func createIndex(_ create: SQLCreateIndex, txn: borrowing WriteTxn) throws(DBError) {
    if try txn.schema().indexes[create.definition.name] != nil {
      if create.ifNotExists { return }
      throw DBError.invalidDefinition("index \(create.definition.name) already exists")
    }
    try txn.createIndex(create.definition)
  }

  static func dropTable(_ name: String, ifExists: Bool, txn: borrowing WriteTxn) throws(DBError) {
    let schema = try txn.schema()
    if schema.tables[name] == nil, schema.ftsTables[name] == nil {
      if ifExists { return }
      throw DBError.noSuchTable(name)
    }
    try txn.dropTable(name)
  }

  static func dropIndex(_ name: String, ifExists: Bool, txn: borrowing WriteTxn) throws(DBError) {
    if try txn.schema().indexes[name] == nil {
      if ifExists { return }
      throw DBError.noSuchIndex(name)
    }
    try txn.dropIndex(name)
  }

  // MARK: - INSERT

  static func insert(
    _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    let schema = try txn.schema()
    if schema.ftsTables[insert.table] != nil {
      return try insertFTS(insert, txn: txn, params: params)
    }
    guard let definition = schema.tables[insert.table] else {
      throw DBError.noSuchTable(insert.table)
    }
    var conflict: ConflictPolicy = .abort
    var upsert: (target: String, sets: [SQLAssignment])?
    switch insert.conflict {
    case .abort: conflict = .abort
    case .replace: conflict = .replace
    case .ignore: conflict = .ignore
    case .doUpdate(let target, let sets):
      guard definition.columnIndex(of: target) != nil else {
        throw DBError.noSuchColumn(table: insert.table, column: target)
      }
      upsert = (target, sets)
    }

    let columnNames = insert.columns.isEmpty ? definition.columns.map(\.name) : insert.columns
    var columnSlots: [Int] = []
    columnSlots.reserveCapacity(columnNames.count)
    for name in columnNames {
      guard let slot = definition.columnIndex(of: name) else {
        throw DBError.noSuchColumn(table: insert.table, column: name)
      }
      columnSlots.append(slot)
    }

    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let returning = try bindReturning(insert.returning, definition: definition)
    let header = returning.map { SQLColumnHeader($0.map(\.name)) }
    var returningRows: [SQLRow] = []
    var changes = 0
    var lastRowid: Int64 = 0

    func recordReturning(rowid: Int64) throws(DBError) {
      guard let returning, let header else { return }
      guard let row = try txn.row(in: insert.table, rowid: rowid) else {
        throw DBError.integrityFailure("RETURNING row \(rowid) vanished")
      }
      returningRows.append(
        try projectRow(returning, table: definition, values: row.values, header: header, params: params))
    }

    func insertRow(_ rowValues: [Value]) throws(DBError) {
      guard rowValues.count == columnNames.count else {
        throw DBError.sqlBind(
          "\(rowValues.count) values for \(columnNames.count) columns in INSERT")
      }
      if let upsert {
        var values: [String: Value] = [:]
        for (index, value) in rowValues.enumerated() { values[columnNames[index]] = value }
        try applyUpsert(
          values, target: upsert.target, sets: upsert.sets, table: insert.table,
          definition: definition, schema: schema, txn: txn, params: params,
          changes: &changes, lastRowid: &lastRowid, record: recordReturning)
        return
      }
      guard
        let rowid = try txn.insertAssembled(
          into: insert.table, columnSlots: columnSlots, values: rowValues, onConflict: conflict)
      else {
        return  // OR IGNORE skipped a conflicting row
      }
      changes += 1
      lastRowid = rowid
      try recordReturning(rowid: rowid)
    }

    switch insert.source {
    case .values(let rows):
      for rowExprs in rows {
        var rowValues: [Value] = []
        rowValues.reserveCapacity(rowExprs.count)
        for expr in rowExprs { rowValues.append(try SQLEval.evaluate(expr, paramsEnv)) }
        try insertRow(rowValues)
      }
    case .select(let select):
      // Materialize the full result first (Halloween-safe for INSERT … SELECT
      // reading the target table), then insert positionally.
      for rowValues in try runSelectInTxn(select, txn: txn, params: params) {
        try insertRow(rowValues)
      }
    }
    return (returningRows, RunResult(changes: changes, lastInsertRowid: lastRowid))
  }

  // MARK: - ON CONFLICT DO UPDATE (upsert)

  /// Inserts the candidate row, or — when it conflicts on the target unique
  /// column — applies the DO UPDATE SET against the existing row with the
  /// proposed row visible as `excluded.*`.
  static func applyUpsert(
    _ candidate: [String: Value], target: String, sets: [SQLAssignment], table: String,
    definition: TableDefinition, schema: Schema, txn: borrowing WriteTxn, params: SQLParameters,
    changes: inout Int, lastRowid: inout Int64, record: (Int64) throws(DBError) -> Void
  ) throws(DBError) {
    let existingRowid: Int64?
    if case .rowidAlias(let aliasColumn, _) = definition.primaryKey, aliasColumn == target {
      if case .integer(let candidateRowid)? = candidate[target],
        try txn.row(in: table, rowid: candidateRowid) != nil {
        existingRowid = candidateRowid
      } else {
        existingRowid = nil
      }
    } else {
      guard let index = schema.indexes(on: table).first(where: {
        $0.unique && $0.columns.count == 1 && $0.columns[0].lowercased() == target.lowercased()
      }) else {
        throw DBError.sqlBind("ON CONFLICT target \(target) is not a unique column")
      }
      if let value = candidate[target], !value.isNull {
        existingRowid = try txn.firstRowid(index: index.name, equals: [value])
      } else {
        existingRowid = nil  // NULLs never collide in a unique index
      }
    }

    guard let rowid = existingRowid else {
      if let inserted = try txn.insert(into: table, candidate, onConflict: .abort) {
        changes += 1
        lastRowid = inserted
        try record(inserted)
      }
      return
    }

    guard let existing = try txn.row(in: table, rowid: rowid) else {
      throw DBError.integrityFailure("upsert target row \(rowid) vanished")
    }
    let env = excludedEnv(
      candidate: candidate, existing: existing.values, definition: definition, params: params)
    var setValues: [String: Value] = [:]
    for assignment in sets {
      guard definition.columnIndex(of: assignment.column) != nil else {
        throw DBError.noSuchColumn(table: table, column: assignment.column)
      }
      setValues[assignment.column] = try SQLEval.evaluate(assignment.value, env)
    }
    _ = try txn.update(table, rowid: rowid, set: setValues)
    changes += 1
    lastRowid = rowid
    try record(rowid)
  }

  /// SET-expression env for DO UPDATE: `excluded.col` is the proposed insert
  /// value (or the column default when not supplied); a bare/table-qualified
  /// column is the existing row's value.
  static func excludedEnv(
    candidate: [String: Value], existing: [Value], definition: TableDefinition,
    params: SQLParameters
  ) -> SQLEvalEnv {
    SQLEvalEnv(
      parameter: { p throws(DBError) in try params.lookup(p) },
      column: { (qualifier, name, _) throws(DBError) in
        if let qualifier, qualifier.lowercased() == "excluded" {
          if let value = candidate[name] { return value }
          guard let column = definition.columns.first(where: { $0.name == name }) else {
            throw DBError.noSuchColumn(table: "excluded", column: name)
          }
          switch column.defaultValue {
          case .value(let value): return value
          case .datetimeNow: return .text(CivilTime.utcNowString())
          case nil: return .null
          }
        }
        guard let index = definition.columnIndex(of: name) else {
          throw DBError.noSuchColumn(table: definition.name, column: name)
        }
        return existing[index]
      },
      collationOf: { (_, name) in
        definition.columnIndex(of: name).map { definition.columns[$0].collation }
      },
      columnTypeOf: { (_, name) in
        definition.columnIndex(of: name).map { definition.columns[$0].type }
      },
      scalarSubquery: { _ throws(DBError) in
        throw DBError.sqlUnsupported("subquery in this context")
      })
  }

  // MARK: - Reading within a write transaction (INSERT … SELECT, subqueries)

  /// Binds and runs a SELECT/compound over a write transaction's own state,
  /// returning fully materialized rows.
  static func runSelectInTxn(
    _ select: SQLSelect, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> [[Value]] {
    switch try Binder.bindQuery(select, schema: try txn.schema()) {
    case .select(let plan):
      return try runBoundSelect(plan, txn: txn, params: params).map(\.values)
    case .compound(let compound):
      var combined: [[Value]] = []
      for (position, arm) in compound.arms.enumerated() {
        let armRows = try runBoundSelect(arm.select, txn: txn, params: params).map(\.values)
        if position == 0 {
          combined = armRows
        } else if arm.op == .unionAll {
          combined += armRows
        } else {
          combined = SelectExecutor.distinctRows(
            combined + armRows, collations: compound.outputCollations)
        }
      }
      return try SelectExecutor.finishCompound(combined, compound: compound, params: params)
        .map(\.values)
    }
  }

  private static func runBoundSelect(
    _ plan: BoundSelect, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> [SQLRow] {
    var tables: [Catalog.TableRecord] = []
    for binding in plan.binding.tables { tables.append(try txn.tableRecord(binding.table)) }
    var index: Catalog.IndexRecord?
    if let name = plan.access.indexName { index = try txn.indexRecord(name) }
    var joinIndexes: [Catalog.IndexRecord?] = []
    for join in plan.joins {
      if let name = join.access.indexName {
        joinIndexes.append(try txn.indexRecord(name))
      } else {
        joinIndexes.append(nil)
      }
    }
    return try SelectExecutor.run(
      plan, tables: tables, index: index, joinIndexes: joinIndexes, resolver: txn.ctx, params: params)
  }

  // MARK: - UPDATE (two-phase)

  static func update(
    _ update: SQLUpdate, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    let schema = try txn.schema()
    guard let definition = schema.tables[update.table] else {
      throw DBError.noSuchTable(update.table)
    }
    for assignment in update.sets where definition.columnIndex(of: assignment.column) == nil {
      throw DBError.noSuchColumn(table: update.table, column: assignment.column)
    }
    let returning = try bindReturning(update.returning, definition: definition)
    let header = returning.map { SQLColumnHeader($0.map(\.name)) }

    // Phase 1: collect matching rows (the predicate sees pre-update values).
    let matches = try collectMatches(update.whereExpr, table: definition, txn: txn, params: params)

    // Phase 2: apply SET (evaluated against each row's pre-update values).
    var returningRows: [SQLRow] = []
    var changes = 0
    for match in matches {
      let env = rowEnv(table: definition, values: match.values, params: params)
      var assignments: [String: Value] = [:]
      for set in update.sets { assignments[set.column] = try SQLEval.evaluate(set.value, env) }
      guard try txn.update(update.table, rowid: match.rowid, set: assignments) else { continue }
      changes += 1
      if let returning, let header {
        guard let row = try txn.row(in: update.table, rowid: match.rowid) else { continue }
        returningRows.append(
          try projectRow(returning, table: definition, values: row.values, header: header, params: params))
      }
    }
    return (returningRows, RunResult(changes: changes, lastInsertRowid: 0))
  }

  // MARK: - DELETE (two-phase)

  static func delete(
    _ delete: SQLDelete, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    let schema = try txn.schema()
    if schema.ftsTables[delete.table] != nil {
      return try deleteFTS(delete, txn: txn, params: params)
    }
    guard let definition = schema.tables[delete.table] else {
      throw DBError.noSuchTable(delete.table)
    }
    let returning = try bindReturning(delete.returning, definition: definition)
    let header = returning.map { SQLColumnHeader($0.map(\.name)) }

    let matches = try collectMatches(delete.whereExpr, table: definition, txn: txn, params: params)

    // RETURNING reports the pre-delete row, so project before deleting.
    var returningRows: [SQLRow] = []
    if let returning, let header {
      for match in matches {
        returningRows.append(
          try projectRow(returning, table: definition, values: match.values, header: header, params: params))
      }
    }
    var changes = 0
    for match in matches where try txn.delete(from: delete.table, rowid: match.rowid) {
      changes += 1
    }
    return (returningRows, RunResult(changes: changes, lastInsertRowid: 0))
  }

  // MARK: - FTS write (self-contained; F2b)

  static func insertFTS(
    _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    guard insert.returning.isEmpty else { throw DBError.sqlUnsupported("RETURNING on an FTS table") }
    guard insert.conflict == .abort else {
      throw DBError.sqlUnsupported("INSERT OR …/upsert on an FTS table")
    }
    guard let definition = try txn.schema().ftsTables[insert.table] else {
      throw DBError.noSuchTable(insert.table)
    }
    // The fts5 command idiom: a first column named after the table carries a
    // command ('delete' / 'delete-all') in its value rather than row content.
    if insert.columns.first == insert.table {
      return try ftsCommand(insert, txn: txn, params: params)
    }
    // Map each INSERT column to an FTS column index, or the implicit rowid slot.
    let targetNames = insert.columns.isEmpty ? definition.columns : insert.columns
    var rowidSlot: Int?
    var ftsColumnForSlot: [Int?] = []
    ftsColumnForSlot.reserveCapacity(targetNames.count)
    for (position, name) in targetNames.enumerated() {
      if name.lowercased() == "rowid" {
        rowidSlot = position
        ftsColumnForSlot.append(nil)
      } else if let column = definition.columns.firstIndex(of: name) {
        ftsColumnForSlot.append(column)
      } else {
        throw DBError.noSuchColumn(table: insert.table, column: name)
      }
    }

    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    var changes = 0
    var lastRowid: Int64 = 0

    func indexRow(_ values: [Value]) throws(DBError) {
      guard values.count == targetNames.count else {
        throw DBError.sqlBind("\(values.count) values for \(targetNames.count) columns in INSERT")
      }
      var texts = [String](repeating: "", count: definition.columns.count)
      var explicitRowid: Int64?
      for (position, value) in values.enumerated() {
        if position == rowidSlot {
          explicitRowid = try ftsRowid(value)
        } else if let column = ftsColumnForSlot[position] {
          texts[column] = ftsText(value)
        }
      }
      let docid: Int64
      if let explicitRowid { docid = explicitRowid } else { docid = try txn.ftsNextRowid(insert.table) }
      try txn.ftsAdd(insert.table, docid: docid, columnTexts: texts)
      changes += 1
      lastRowid = docid
    }

    switch insert.source {
    case .values(let rows):
      for rowExprs in rows {
        var values: [Value] = []
        values.reserveCapacity(rowExprs.count)
        for expr in rowExprs { values.append(try SQLEval.evaluate(expr, paramsEnv)) }
        try indexRow(values)
      }
    case .select(let select):
      for values in try runSelectInTxn(select, txn: txn, params: params) { try indexRow(values) }
    }
    return ([], RunResult(changes: changes, lastInsertRowid: lastRowid))
  }

  /// The fts5 command idiom (`INSERT INTO fts(fts, …) VALUES('delete'|'delete-all', …)`).
  /// `'delete'` removes the named rowid (driven by the stored forward record);
  /// `'delete-all'` clears the index. Other commands are unsupported.
  private static func ftsCommand(
    _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    guard case .values(let rows) = insert.source else {
      throw DBError.sqlUnsupported("FTS command requires VALUES")
    }
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let rowidPosition = insert.columns.firstIndex { $0.lowercased() == "rowid" }
    var changes = 0
    for rowExprs in rows {
      guard rowExprs.count == insert.columns.count else {
        throw DBError.sqlBind("FTS command: \(rowExprs.count) values for \(insert.columns.count) columns")
      }
      var values: [Value] = []
      values.reserveCapacity(rowExprs.count)
      for expr in rowExprs { values.append(try SQLEval.evaluate(expr, paramsEnv)) }
      guard case .text(let command) = values[0] else {
        throw DBError.sqlBind("FTS command must be a text value")
      }
      switch command {
      case "delete":
        guard let rowidPosition else {
          throw DBError.sqlBind("FTS 'delete' requires a rowid column")
        }
        if try txn.ftsRemove(insert.table, docid: ftsRowid(values[rowidPosition])) { changes += 1 }
      case "delete-all":
        try txn.ftsRemoveAll(insert.table)
      default:
        throw DBError.sqlUnsupported("FTS command '\(command)'")
      }
    }
    return ([], RunResult(changes: changes, lastInsertRowid: 0))
  }

  static func deleteFTS(
    _ delete: SQLDelete, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
    guard delete.returning.isEmpty else { throw DBError.sqlUnsupported("RETURNING on an FTS table") }
    let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
    let docids = try ftsDeleteDocids(delete.whereExpr, env: paramsEnv)
    var changes = 0
    for docid in docids where try txn.ftsRemove(delete.table, docid: docid) { changes += 1 }
    return ([], RunResult(changes: changes, lastInsertRowid: 0))
  }

  /// Extracts docids from `WHERE rowid = expr` / `rowid IN (exprs)`; other shapes
  /// are unsupported (apple-docs deletes FTS rows by rowid).
  private static func ftsDeleteDocids(
    _ predicate: SQLExpr?, env: SQLEvalEnv
  ) throws(DBError) -> [Int64] {
    guard let predicate else {
      throw DBError.sqlUnsupported("DELETE FROM fts requires WHERE rowid = …")
    }
    func isRowid(_ expr: SQLExpr) -> Bool {
      if case .column(_, let name, _) = expr { return name.lowercased() == "rowid" }
      return false
    }
    switch predicate {
    case .binary(.eq, let lhs, let rhs):
      if isRowid(lhs) { return [try ftsRowid(try SQLEval.evaluate(rhs, env))] }
      if isRowid(rhs) { return [try ftsRowid(try SQLEval.evaluate(lhs, env))] }
    case .inList(let target, let items, let negated) where !negated && isRowid(target):
      var docids: [Int64] = []
      for item in items { docids.append(try ftsRowid(try SQLEval.evaluate(item, env))) }
      return docids
    default:
      break
    }
    throw DBError.sqlUnsupported("FTS DELETE supports only WHERE rowid = … or rowid IN (…)")
  }

  private static func ftsRowid(_ value: Value) throws(DBError) -> Int64 {
    guard case .integer(let rowid) = value else {
      throw DBError.sqlBind("FTS rowid must be an integer")
    }
    return rowid
  }

  private static func ftsText(_ value: Value) -> String {
    switch value {
    case .text(let text): return text
    case .null: return ""
    case .integer(let v): return String(v)
    case .real(let v): return String(v)
    case .blob: return ""
    }
  }

  /// Phase 1 of UPDATE/DELETE: every rowid (with its current values) whose row
  /// satisfies the predicate, collected before any mutation (Halloween-safe).
  static func collectMatches(
    _ predicate: SQLExpr?, table: TableDefinition, txn: borrowing WriteTxn, params: SQLParameters
  ) throws(DBError) -> [(rowid: Int64, values: [Value])] {
    try txn.withRowCursor(table: table.name) { (cursor) throws(DBError) in
      var matches: [(rowid: Int64, values: [Value])] = []
      while let row = try cursor.next() {
        if let predicate {
          let env = rowEnv(table: table, values: row.values, params: params)
          if SQLEval.truth(try SQLEval.evaluate(predicate, env)) != .yes { continue }
        }
        matches.append((row.rowid, row.values))
      }
      return matches
    }
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

  /// Evaluates the RETURNING expressions against a row's values.
  static func projectRow(
    _ returning: [(name: String, expr: SQLExpr)], table: TableDefinition, values rowValues: [Value],
    header: SQLColumnHeader, params: SQLParameters
  ) throws(DBError) -> SQLRow {
    let env = rowEnv(table: table, values: rowValues, params: params)
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
