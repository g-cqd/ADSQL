/// Recursive-descent parser for the ADSQL SQL subset (SQLite syntax).
/// Constructs outside the subset fail with `sqlUnsupported` naming the
/// construct; malformed input fails with `sqlSyntax` carrying the offset.
struct SQLParser {
  let sql: [UInt8]
  let tokens: [SQLToken]
  var pos = 0
  /// Bounds expression nesting so hostile input (`((((…))))`, `NOT NOT …`,
  /// `- - …`) fails with a syntax error instead of overflowing the stack.
  var exprDepth = 0
  /// The Pratt parser spends ~3–5 stack frames per nesting level (vs ~12 for
  /// the former recursive-descent chain), so this stays safe even on a small
  /// (512 KiB Dispatch-thread) debug stack while comfortably exceeding any real
  /// query's nesting.
  static let maxExprDepth = 48

  mutating func enterExprNesting() throws(DBError) {
    exprDepth += 1
    guard exprDepth <= Self.maxExprDepth else {
      throw DBError.sqlSyntax(message: "expression nesting too deep", offset: current.offset)
    }
  }

  static func parseScript(_ sql: String) throws(DBError) -> [SQLStatementAST] {
    var parser = SQLParser(sql: Array(sql.utf8), tokens: try SQLLexer.tokenize(sql))
    var statements: [SQLStatementAST] = []
    while !parser.atEnd {
      if parser.matchSymbol(";") { continue }
      statements.append(try parser.statement())
    }
    return statements
  }

  static func parseOne(_ sql: String) throws(DBError) -> SQLStatementAST {
    let statements = try parseScript(sql)
    guard statements.count == 1 else {
      throw DBError.sqlSyntax(
        message: "expected exactly one statement, found \(statements.count)", offset: 0)
    }
    return statements[0]
  }

  // MARK: - Token helpers

  var atEnd: Bool {
    if case .end = tokens[pos].kind { return true }
    return false
  }
  var current: SQLToken { tokens[pos] }

  mutating func advance() -> SQLToken {
    let token = tokens[pos]
    if !atEnd { pos += 1 }
    return token
  }

  func checkKeyword(_ kw: String, _ ahead: Int = 0) -> Bool {
    if case .keyword(let k) = tokens[min(pos + ahead, tokens.count - 1)].kind { return k == kw }
    return false
  }
  func checkSymbol(_ s: String) -> Bool {
    if case .symbol(let v) = current.kind { return v == s }
    return false
  }

  mutating func matchKeyword(_ kw: String) -> Bool {
    if checkKeyword(kw) {
      pos += 1
      return true
    }
    return false
  }
  mutating func matchSymbol(_ s: String) -> Bool {
    if checkSymbol(s) {
      pos += 1
      return true
    }
    return false
  }

  mutating func expectKeyword(_ kw: String) throws(DBError) {
    guard matchKeyword(kw) else {
      throw DBError.sqlSyntax(message: "expected \(kw)", offset: current.offset)
    }
  }
  mutating func expectSymbol(_ s: String) throws(DBError) {
    guard matchSymbol(s) else {
      throw DBError.sqlSyntax(message: "expected '\(s)'", offset: current.offset)
    }
  }

  mutating func identifier(_ what: String) throws(DBError) -> String {
    if case .identifier(let name) = current.kind {
      pos += 1
      return name
    }
    // Non-reserved keywords usable as identifiers (column named "key" etc.)
    if case .keyword(let kw) = current.kind, identifierKeywords.contains(kw) {
      pos += 1
      return kw.lowercased()
    }
    throw DBError.sqlSyntax(message: "expected \(what)", offset: current.offset)
  }

  /// Keywords we tokenize but allow as plain identifiers in name position.
  /// The trigger-grammar words (AFTER/BEFORE/…) are non-reserved in SQLite, so
  /// they stay usable as table/column names outside a CREATE TRIGGER header.
  let identifierKeywords: Set<String> = [
    "KEY", "MATCH", "REPLACE", "DO", "COLUMN", "ADD", "TO",
    "AFTER", "BEFORE", "INSTEAD", "FOR", "EACH", "ROW", "OF",
  ]

  func sourceText(from startOffset: Int, to endOffset: Int) -> String {
    var lo = startOffset
    var hi = min(endOffset, sql.count)
    while lo < hi, sql[lo] == 0x20 || sql[lo] == 0x0A || sql[lo] == 0x09 { lo += 1 }
    while hi > lo, sql[hi - 1] == 0x20 || sql[hi - 1] == 0x0A || sql[hi - 1] == 0x09 { hi -= 1 }
    return String(decoding: sql[lo..<hi], as: UTF8.self)
  }

  // MARK: - Statements

  mutating func statement() throws(DBError) -> SQLStatementAST {
    let offset = current.offset
    if checkKeyword("WITH") { throw DBError.sqlUnsupported("common table expressions (WITH)") }
    if matchKeyword("PRAGMA") { return try pragma() }
    if checkKeyword("EXPLAIN") { throw DBError.sqlUnsupported("EXPLAIN") }
    if checkKeyword("VACUUM") { throw DBError.sqlUnsupported("VACUUM") }
    if checkKeyword("ALTER") { throw DBError.sqlUnsupported("ALTER TABLE") }
    if matchKeyword("SELECT") {
      pos -= 1
      return .select(try select())
    }
    if matchKeyword("INSERT") { return .insert(try insert(offset: offset, replaceForm: false)) }
    if matchKeyword("REPLACE") {
      // REPLACE INTO ≡ INSERT OR REPLACE INTO
      return .insert(try insert(offset: offset, replaceForm: true))
    }
    if matchKeyword("UPDATE") { return .update(try update(offset: offset)) }
    if matchKeyword("DELETE") { return .delete(try delete(offset: offset)) }
    if matchKeyword("CREATE") { return try create(startOffset: offset) }
    if matchKeyword("DROP") { return try drop() }
    if matchKeyword("BEGIN") {
      _ = matchKeyword("IMMEDIATE") || matchKeyword("DEFERRED") || matchKeyword("EXCLUSIVE")
      _ = matchKeyword("TRANSACTION")
      return .begin
    }
    if matchKeyword("COMMIT") {
      _ = matchKeyword("TRANSACTION")
      return .commit
    }
    if matchKeyword("ROLLBACK") {
      _ = matchKeyword("TRANSACTION")
      return .rollback
    }
    throw DBError.sqlSyntax(message: "expected a statement", offset: current.offset)
  }

  /// `PRAGMA name` / `PRAGMA name = value` / `PRAGMA name(value)`. The name and
  /// value are taken loosely (pragma names aren't reserved; values may be
  /// identifiers like WAL/OFF, keywords like DELETE, strings, or numbers).
  mutating func pragma() throws(DBError) -> SQLStatementAST {
    let name = try pragmaWord()
    var value: String?
    if matchSymbol("=") {
      value = try pragmaWord()
    } else if matchSymbol("(") {
      value = try pragmaWord()
      try expectSymbol(")")
    }
    return .pragma(name: name.lowercased(), value: value)
  }

  /// One pragma name/value token, stringified. A leading sign is accepted so
  /// numeric values like `cache_size = -64000` parse.
  mutating func pragmaWord() throws(DBError) -> String {
    var sign = ""
    if matchSymbol("-") { sign = "-" } else if matchSymbol("+") { sign = "" }
    let token = advance()
    switch token.kind {
    case .identifier(let s): return sign + s
    case .keyword(let s): return sign + s
    case .string(let s): return s
    case .integer(let v): return sign + String(v)
    case .real(let d): return sign + String(d)
    default:
      throw DBError.sqlSyntax(message: "expected a pragma name or value", offset: token.offset)
    }
  }

  // MARK: SELECT

  mutating func select() throws(DBError) -> SQLSelect {
    var stmt = try selectCore()
    while checkKeyword("UNION") || checkKeyword("EXCEPT") || checkKeyword("INTERSECT") {
      if matchKeyword("UNION") {
        let op: SQLCompoundOp = matchKeyword("ALL") ? .unionAll : .union
        stmt.compounds.append(SQLCompound(op: op, select: try selectCore()))
      } else {
        throw DBError.sqlUnsupported("EXCEPT/INTERSECT compound queries")
      }
    }
    if matchKeyword("ORDER") {
      try expectKeyword("BY")
      repeat {
        let expr = try expression()
        var descending = false
        if matchKeyword("DESC") { descending = true } else { _ = matchKeyword("ASC") }
        stmt.orderBy.append(SQLOrderingTerm(expr: expr, descending: descending))
      } while matchSymbol(",")
    }
    if matchKeyword("LIMIT") {
      stmt.limit = try expression()
      if matchSymbol(",") {
        throw DBError.sqlUnsupported("LIMIT offset, count form (use LIMIT ... OFFSET ...)")
      }
      if matchKeyword("OFFSET") { stmt.offset = try expression() }
    }
    return stmt
  }

  mutating func selectCore() throws(DBError) -> SQLSelect {
    try expectKeyword("SELECT")
    var stmt = SQLSelect()
    if matchKeyword("DISTINCT") { stmt.distinct = true } else { _ = matchKeyword("ALL") }

    repeat {
      if matchSymbol("*") {
        stmt.columns.append(.star)
        continue
      }
      // t.* form
      if case .identifier(let name) = current.kind,
        case .symbol(".") = tokens[pos + 1].kind,
        case .symbol("*") = tokens[pos + 2].kind {
        pos += 3
        stmt.columns.append(.tableStar(name))
        continue
      }
      let start = current.offset
      let expr = try expression()
      let end = current.offset
      var alias: String?
      if matchKeyword("AS") {
        alias = try identifier("alias")
      } else if case .identifier(let name) = current.kind {
        pos += 1
        alias = name
      }
      stmt.columns.append(
        .expr(expr, alias: alias, sourceText: sourceText(from: start, to: end)))
    } while matchSymbol(",")

    if matchKeyword("FROM") {
      if checkSymbol("(") { throw DBError.sqlUnsupported("subqueries in FROM") }
      stmt.from = try tableRef()
      while true {
        if checkKeyword("NATURAL") || checkKeyword("RIGHT") || checkKeyword("FULL")
          || checkKeyword("CROSS") {
          throw DBError.sqlUnsupported("NATURAL/RIGHT/FULL/CROSS joins")
        }
        let kind: SQLJoinKind
        if matchKeyword("LEFT") {
          _ = matchKeyword("OUTER")
          try expectKeyword("JOIN")
          kind = .left
        } else if matchKeyword("INNER") {
          try expectKeyword("JOIN")
          kind = .inner
        } else if matchKeyword("JOIN") {
          kind = .inner
        } else if matchSymbol(",") {
          throw DBError.sqlUnsupported("comma joins (use explicit JOIN ... ON)")
        } else {
          break
        }
        let table = try tableRef()
        if checkKeyword("USING") { throw DBError.sqlUnsupported("JOIN ... USING") }
        try expectKeyword("ON")
        stmt.joins.append(SQLJoin(kind: kind, table: table, on: try expression()))
      }
    }
    if matchKeyword("WHERE") { stmt.whereExpr = try expression() }
    if matchKeyword("GROUP") {
      try expectKeyword("BY")
      repeat {
        stmt.groupBy.append(try expression())
      } while matchSymbol(",")
      if matchKeyword("HAVING") { stmt.having = try expression() }
    } else if checkKeyword("HAVING") {
      throw DBError.sqlSyntax(message: "HAVING requires GROUP BY", offset: current.offset)
    }
    return stmt
  }

  mutating func tableRef() throws(DBError) -> SQLTableRef {
    let offset = current.offset
    let name = try identifier("table name")
    var alias: String?
    if matchKeyword("AS") {
      alias = try identifier("alias")
    } else if case .identifier(let a) = current.kind {
      pos += 1
      alias = a
    }
    return SQLTableRef(name: name, alias: alias, offset: offset)
  }

  // MARK: INSERT / UPDATE / DELETE

  mutating func insert(offset: Int, replaceForm: Bool) throws(DBError) -> SQLInsert {
    var conflict: SQLInsert.Conflict = replaceForm ? .replace : .abort
    if !replaceForm, matchKeyword("OR") {
      if matchKeyword("REPLACE") {
        conflict = .replace
      } else if matchKeyword("IGNORE") {
        conflict = .ignore
      } else {
        throw DBError.sqlUnsupported("INSERT OR <\(current)> (only REPLACE/IGNORE)")
      }
    }
    try expectKeyword("INTO")
    let table = try identifier("table name")
    var columns: [String] = []
    if matchSymbol("(") {
      repeat {
        columns.append(try identifier("column name"))
      } while matchSymbol(",")
      try expectSymbol(")")
    }
    let source: SQLInsert.Source
    if checkKeyword("SELECT") {
      source = .select(try select())
    } else {
      try expectKeyword("VALUES")
      var rows: [[SQLExpr]] = []
      repeat {
        try expectSymbol("(")
        var row: [SQLExpr] = []
        repeat {
          row.append(try expression())
        } while matchSymbol(",")
        try expectSymbol(")")
        rows.append(row)
      } while matchSymbol(",")
      source = .values(rows)
    }

    if matchKeyword("ON") {
      try expectKeyword("CONFLICT")
      guard case .abort = conflict else {
        throw DBError.sqlSyntax(
          message: "ON CONFLICT cannot combine with OR REPLACE/IGNORE", offset: current.offset)
      }
      try expectSymbol("(")
      let target = try identifier("conflict target column")
      try expectSymbol(")")
      try expectKeyword("DO")
      if matchKeyword("UPDATE") {
        try expectKeyword("SET")
        var sets: [SQLAssignment] = []
        repeat {
          let columnOffset = current.offset
          let column = try identifier("column name")
          try expectSymbol("=")
          sets.append(
            SQLAssignment(column: column, value: try expression(), offset: columnOffset))
        } while matchSymbol(",")
        if checkKeyword("WHERE") {
          throw DBError.sqlUnsupported("ON CONFLICT ... DO UPDATE ... WHERE")
        }
        conflict = .doUpdate(target: target, sets: sets)
      } else {
        // DO NOTHING ≈ OR IGNORE for this engine.
        guard case .identifier(let word) = advance().kind, word.uppercased() == "NOTHING" else {
          throw DBError.sqlSyntax(message: "expected UPDATE or NOTHING", offset: current.offset)
        }
        conflict = .ignore
      }
    }
    let returning = try returningClause()
    return SQLInsert(
      table: table, columns: columns, source: source, conflict: conflict,
      returning: returning, offset: offset)
  }

  mutating func update(offset: Int) throws(DBError) -> SQLUpdate {
    let table = try identifier("table name")
    try expectKeyword("SET")
    var sets: [SQLAssignment] = []
    repeat {
      let columnOffset = current.offset
      let column = try identifier("column name")
      try expectSymbol("=")
      sets.append(SQLAssignment(column: column, value: try expression(), offset: columnOffset))
    } while matchSymbol(",")
    let whereExpr = matchKeyword("WHERE") ? try expression() : nil
    let returning = try returningClause()
    return SQLUpdate(
      table: table, sets: sets, whereExpr: whereExpr, returning: returning, offset: offset)
  }

  mutating func delete(offset: Int) throws(DBError) -> SQLDelete {
    try expectKeyword("FROM")
    let table = try identifier("table name")
    let whereExpr = matchKeyword("WHERE") ? try expression() : nil
    let returning = try returningClause()
    return SQLDelete(table: table, whereExpr: whereExpr, returning: returning, offset: offset)
  }

  mutating func returningClause() throws(DBError) -> [SQLResultColumn] {
    guard matchKeyword("RETURNING") else { return [] }
    var columns: [SQLResultColumn] = []
    repeat {
      if matchSymbol("*") {
        columns.append(.star)
        continue
      }
      let start = current.offset
      let expr = try expression()
      let end = current.offset
      var alias: String?
      if matchKeyword("AS") { alias = try identifier("alias") }
      columns.append(.expr(expr, alias: alias, sourceText: sourceText(from: start, to: end)))
    } while matchSymbol(",")
    return columns
  }

  // MARK: DDL

  mutating func create(startOffset: Int) throws(DBError) -> SQLStatementAST {
    if matchKeyword("VIRTUAL") { return try createVirtualTable() }
    if matchKeyword("TRIGGER") { return try createTrigger(startOffset: startOffset) }
    if checkKeyword("VIEW") { throw DBError.sqlUnsupported("CREATE VIEW") }
    let unique = matchKeyword("UNIQUE")
    if matchKeyword("INDEX") {
      let ifNotExists = try ifNotExistsClause()
      let name = try identifier("index name")
      try expectKeyword("ON")
      let table = try identifier("table name")
      try expectSymbol("(")
      var columns: [String] = []
      repeat {
        columns.append(try identifier("column name"))
        if matchKeyword("COLLATE") { _ = try collationName() }
        if matchKeyword("DESC") { throw DBError.sqlUnsupported("DESC index columns") }
        _ = matchKeyword("ASC")
      } while matchSymbol(",")
      try expectSymbol(")")
      if checkKeyword("WHERE") { throw DBError.sqlUnsupported("partial indexes") }
      return .createIndex(SQLCreateIndex(
        definition: IndexDefinition(name, on: table, columns: columns, unique: unique),
        ifNotExists: ifNotExists))
    }
    guard !unique else {
      throw DBError.sqlSyntax(message: "expected INDEX after UNIQUE", offset: current.offset)
    }
    try expectKeyword("TABLE")
    let ifNotExists = try ifNotExistsClause()
    let name = try identifier("table name")
    return .createTable(try createTableBody(name: name, ifNotExists: ifNotExists))
  }

  /// `CREATE VIRTUAL TABLE [IF NOT EXISTS] <name> USING fts5(col…, option=…)`.
  /// "VIRTUAL" is already consumed. Each parenthesized argument is a bare column
  /// name, or an `option=value` (distinguished by the `=`).
  mutating func createVirtualTable() throws(DBError) -> SQLStatementAST {
    try expectKeyword("TABLE")
    let ifNotExists = try ifNotExistsClause()
    let name = try identifier("virtual table name")
    try expectKeyword("USING")
    let module = try identifier("module name")
    guard module.lowercased() == "fts5" else {
      throw DBError.sqlUnsupported("virtual table module '\(module)' (only fts5)")
    }
    try expectSymbol("(")

    var columns: [String] = []
    var tokenize: [String] = ["unicode61"]
    var contentValue: String?
    var contentRowid: String?
    var contentlessDelete = false
    var prefix: [Int] = []
    var detail: FTSDetail = .full
    var columnSize = true

    repeat {
      let ident = try identifier("column or option")
      if matchSymbol("=") {
        let value = try ftsOptionValue()
        switch ident.lowercased() {
        case "tokenize":
          let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
          tokenize = tokens.isEmpty ? ["unicode61"] : tokens
        case "content":
          contentValue = value
        case "content_rowid":
          contentRowid = value
        case "contentless_delete":
          contentlessDelete = value != "0"
        case "prefix":
          for part in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let size = Int(part), size > 0 else {
              throw DBError.sqlSyntax(
                message: "invalid fts5 prefix '\(part)'", offset: current.offset)
            }
            prefix.append(size)
          }
        case "detail":
          switch value.lowercased() {
          case "full": detail = .full
          case "column": detail = .column
          case "none": detail = .none
          default: throw DBError.sqlUnsupported("fts5 detail '\(value)'")
          }
        case "columnsize":
          columnSize = value != "0"
        default:
          throw DBError.sqlUnsupported("fts5 option '\(ident)'")
        }
      } else {
        columns.append(ident)
      }
    } while matchSymbol(",")
    try expectSymbol(")")

    guard !columns.isEmpty else {
      throw DBError.invalidDefinition("fts5 table \(name) has no columns")
    }
    let content: FTSContentMode
    if let contentValue {
      content = contentValue.isEmpty
        ? .contentless(deleteEnabled: contentlessDelete)
        : .external(table: contentValue, rowid: contentRowid ?? "rowid")
    } else {
      content = .selfContained
    }
    return .createVirtualTable(SQLCreateVirtualTable(
      definition: FTSDefinition(
        name: name, columns: columns, tokenize: tokenize, content: content,
        prefix: prefix, detail: detail, columnSize: columnSize),
      ifNotExists: ifNotExists))
  }

  /// `CREATE TRIGGER [IF NOT EXISTS] <name> AFTER (INSERT|UPDATE|DELETE) ON
  /// <table> [FOR EACH ROW] [WHEN <expr>] BEGIN <stmt>; … END`. "TRIGGER" is
  /// already consumed; `startOffset` is the offset of the `CREATE` keyword so
  /// the whole statement text can be captured verbatim for the catalog.
  ///
  /// Only `AFTER` row triggers are supported (BEFORE/INSTEAD OF → unsupported);
  /// `FOR EACH ROW` is accepted and is also the default (FTS-sync triggers are
  /// all row triggers). The body is a list of INSERT/DELETE/UPDATE statements.
  mutating func createTrigger(startOffset: Int) throws(DBError) -> SQLStatementAST {
    let ifNotExists = try ifNotExistsClause()
    let name = try identifier("trigger name")
    if matchKeyword("BEFORE") { throw DBError.sqlUnsupported("BEFORE triggers") }
    if matchKeyword("INSTEAD") { throw DBError.sqlUnsupported("INSTEAD OF triggers") }
    _ = matchKeyword("AFTER")
    let event: TriggerEvent
    if matchKeyword("INSERT") {
      event = .insert
    } else if matchKeyword("UPDATE") {
      // `UPDATE OF col, …` narrows the columns; unsupported (apple-docs fires on
      // any column change). Reject explicitly rather than silently widening.
      if matchKeyword("OF") { throw DBError.sqlUnsupported("UPDATE OF <columns> triggers") }
      event = .update
    } else if matchKeyword("DELETE") {
      event = .delete
    } else {
      throw DBError.sqlSyntax(
        message: "expected INSERT, UPDATE, or DELETE", offset: current.offset)
    }
    try expectKeyword("ON")
    let table = try identifier("table name")
    if matchKeyword("FOR") {
      try expectKeyword("EACH")
      try expectKeyword("ROW")
    }
    let whenExpr = matchKeyword("WHEN") ? try expression() : nil

    try expectKeyword("BEGIN")
    var body: [SQLStatementAST] = []
    while !checkKeyword("END") {
      body.append(try triggerBodyStatement())
      // Each body statement is terminated by `;` (SQLite requires it); the last
      // one before END must be terminated too.
      try expectSymbol(";")
    }
    guard !body.isEmpty else {
      throw DBError.sqlSyntax(message: "trigger body has no statements", offset: current.offset)
    }
    guard checkKeyword("END") else {
      throw DBError.sqlSyntax(message: "expected END", offset: current.offset)
    }
    let endOffset = current.offset + 3 // "END" is 3 bytes regardless of case
    _ = advance() // consume END

    let sql = sourceText(from: startOffset, to: endOffset)
    return .createTrigger(SQLCreateTrigger(
      definition: TriggerDefinition(
        name: name, table: table, event: event, whenExpr: whenExpr, body: body, sql: sql),
      ifNotExists: ifNotExists))
  }

  /// One statement inside a trigger body: INSERT / DELETE / UPDATE (the row
  /// actions apple-docs's FTS-sync triggers use). SELECT and nested DDL are
  /// rejected — a trigger body mutates, it does not query or define.
  mutating func triggerBodyStatement() throws(DBError) -> SQLStatementAST {
    let offset = current.offset
    if matchKeyword("INSERT") { return .insert(try insert(offset: offset, replaceForm: false)) }
    if matchKeyword("REPLACE") { return .insert(try insert(offset: offset, replaceForm: true)) }
    if matchKeyword("UPDATE") { return .update(try update(offset: offset)) }
    if matchKeyword("DELETE") { return .delete(try delete(offset: offset)) }
    throw DBError.sqlUnsupported("trigger body statement (only INSERT/UPDATE/DELETE)")
  }

  /// One fts5 option value, stringified (`'quoted'`, identifier, or integer).
  mutating func ftsOptionValue() throws(DBError) -> String {
    let token = advance()
    switch token.kind {
    case .string(let s): return s
    case .identifier(let s): return s
    case .keyword(let s): return s
    case .integer(let v): return String(v)
    default:
      throw DBError.sqlSyntax(message: "expected an fts5 option value", offset: token.offset)
    }
  }

  mutating func ifNotExistsClause() throws(DBError) -> Bool {
    if matchKeyword("IF") {
      try expectKeyword("NOT")
      try expectKeyword("EXISTS")
      return true
    }
    return false
  }

  mutating func collationName() throws(DBError) -> Collation {
    let name = try identifier("collation name").uppercased()
    switch name {
    case "BINARY": return .binary
    case "NOCASE": return .nocase
    default: throw DBError.sqlUnsupported("collation \(name)")
    }
  }

  mutating func createTableBody(
    name: String, ifNotExists: Bool
  ) throws(DBError) -> SQLCreateTable {
    try expectSymbol("(")
    var columns: [ColumnDefinition] = []
    var primaryKey: PrimaryKey = .implicitRowid
    var foreignKeys: [ForeignKey] = []
    var uniqueColumnSets: [[String]] = []
    var pkColumns: [String]? // table-level PRIMARY KEY(...)

    repeat {
      if checkKeyword("PRIMARY") || checkKeyword("UNIQUE") || checkKeyword("CHECK")
        || checkKeyword("FOREIGN") {
        // Table constraints
        if matchKeyword("PRIMARY") {
          try expectKeyword("KEY")
          try expectSymbol("(")
          var cols: [String] = []
          repeat { cols.append(try identifier("column name")) } while matchSymbol(",")
          try expectSymbol(")")
          pkColumns = cols
        } else if matchKeyword("UNIQUE") {
          try expectSymbol("(")
          var cols: [String] = []
          repeat { cols.append(try identifier("column name")) } while matchSymbol(",")
          try expectSymbol(")")
          uniqueColumnSets.append(cols)
        } else if matchKeyword("CHECK") {
          try expectSymbol("(")
          _ = try expression() // parsed, discarded
          try expectSymbol(")")
        } else if matchKeyword("FOREIGN") {
          try expectKeyword("KEY")
          try expectSymbol("(")
          var cols: [String] = []
          repeat { cols.append(try identifier("column name")) } while matchSymbol(",")
          try expectSymbol(")")
          let (parent, action) = try referencesClause()
          foreignKeys.append(
            ForeignKey(childColumns: cols, parentTable: parent, onDelete: action))
        }
        continue
      }

      // Column definition
      let columnName = try identifier("column name")
      let type = try columnType()
      var column = ColumnDefinition(columnName, type)
      var columnIsPK = false
      var columnAuto = false
      loop: while true {
        if matchKeyword("PRIMARY") {
          try expectKeyword("KEY")
          _ = matchKeyword("ASC")
          if matchKeyword("DESC") { throw DBError.sqlUnsupported("PRIMARY KEY DESC") }
          columnIsPK = true
          if matchKeyword("AUTOINCREMENT") { columnAuto = true }
        } else if matchKeyword("NOT") {
          try expectKeyword("NULL")
          column.notNull = true
        } else if matchKeyword("UNIQUE") {
          uniqueColumnSets.append([columnName])
        } else if matchKeyword("DEFAULT") {
          column.defaultValue = try defaultClause()
        } else if matchKeyword("COLLATE") {
          column.collation = try collationName()
        } else if matchKeyword("CHECK") {
          try expectSymbol("(")
          _ = try expression()
          try expectSymbol(")")
        } else if matchKeyword("REFERENCES") {
          pos -= 1
          let (parent, action) = try referencesClause()
          foreignKeys.append(
            ForeignKey(childColumns: [columnName], parentTable: parent, onDelete: action))
        } else {
          break loop
        }
      }
      if columnIsPK {
        guard pkColumns == nil, case .implicitRowid = primaryKey else {
          throw DBError.sqlSyntax(message: "multiple primary keys", offset: current.offset)
        }
        if type == .integer {
          primaryKey = .rowidAlias(column: columnName, autoincrement: columnAuto)
        } else {
          guard !columnAuto else {
            throw DBError.sqlSyntax(
              message: "AUTOINCREMENT requires INTEGER PRIMARY KEY", offset: current.offset)
          }
          pkColumns = [columnName]
        }
      }
      columns.append(column)
    } while matchSymbol(",")
    try expectSymbol(")")
    if matchKeyword("STRICT") {} // engine is strict regardless
    if matchKeyword("WITHOUT") { throw DBError.sqlUnsupported("WITHOUT ROWID tables") }

    // Resolve table-level PK.
    if let pkColumns {
      if pkColumns.count == 1,
        let index = columns.firstIndex(where: { $0.name == pkColumns[0] }),
        columns[index].type == .integer,
        case .implicitRowid = primaryKey {
        primaryKey = .rowidAlias(column: pkColumns[0], autoincrement: false)
      } else {
        uniqueColumnSets.insert(pkColumns, at: 0)
        for column in pkColumns {
          if let index = columns.firstIndex(where: { $0.name == column }) {
            columns[index].notNull = true // SQLite PKs are NOT NULL
          }
        }
      }
    }

    var implied: [IndexDefinition] = []
    for (n, cols) in uniqueColumnSets.enumerated() {
      implied.append(IndexDefinition(
        "sqlite_autoindex_\(name)_\(n + 1)", on: name, columns: cols, unique: true))
    }
    return SQLCreateTable(
      definition: TableDefinition(
        name, columns: columns, primaryKey: primaryKey, foreignKeys: foreignKeys),
      impliedIndexes: implied,
      ifNotExists: ifNotExists)
  }

  mutating func columnType() throws(DBError) -> ColumnType {
    if matchKeyword("INTEGER") || matchKeyword("INT") { return .integer }
    if matchKeyword("TEXT") { return .text }
    if matchKeyword("REAL") { return .real }
    if matchKeyword("BLOB") { return .blob }
    throw DBError.sqlSyntax(
      message: "expected a column type (INTEGER/TEXT/REAL/BLOB)", offset: current.offset)
  }

  mutating func defaultClause() throws(DBError) -> DefaultValue {
    if matchSymbol("(") {
      // Parenthesized default expression: only datetime('now') is accepted.
      let expr = try expression()
      try expectSymbol(")")
      if case .function(let fn, let args, _, _) = expr, fn.uppercased() == "DATETIME",
        args == [.literal(.text("now"))] {
        return .datetimeNow
      }
      throw DBError.sqlUnsupported("DEFAULT expressions other than (datetime('now'))")
    }
    let negative = matchSymbol("-")
    switch advance().kind {
    case .integer(let v): return .value(.integer(negative ? -v : v))
    case .real(let d): return .value(.real(negative ? -d : d))
    case .string(let s) where !negative: return .value(.text(s))
    case .keyword("NULL") where !negative: return .value(.null)
    default:
      throw DBError.sqlSyntax(message: "expected a default literal", offset: current.offset)
    }
  }

  mutating func referencesClause() throws(DBError) -> (parent: String, action: FKAction) {
    try expectKeyword("REFERENCES")
    let parent = try identifier("parent table")
    if matchSymbol("(") {
      _ = try identifier("parent column") // must be the rowid alias; name discarded
      try expectSymbol(")")
    }
    var action: FKAction = .restrict // SQLite default NO ACTION ≈ restrict-on-delete here
    while matchKeyword("ON") {
      try expectKeyword("DELETE")
      if matchKeyword("CASCADE") {
        action = .cascade
      } else if matchKeyword("RESTRICT") {
        action = .restrict
      } else {
        throw DBError.sqlUnsupported("ON DELETE actions other than CASCADE/RESTRICT")
      }
    }
    return (parent, action)
  }

  mutating func drop() throws(DBError) -> SQLStatementAST {
    if matchKeyword("TABLE") {
      let ifExists = try ifExistsClause()
      return .dropTable(name: try identifier("table name"), ifExists: ifExists)
    }
    if matchKeyword("INDEX") {
      let ifExists = try ifExistsClause()
      return .dropIndex(name: try identifier("index name"), ifExists: ifExists)
    }
    if matchKeyword("TRIGGER") {
      let ifExists = try ifExistsClause()
      return .dropTrigger(name: try identifier("trigger name"), ifExists: ifExists)
    }
    throw DBError.sqlSyntax(message: "expected TABLE, INDEX, or TRIGGER", offset: current.offset)
  }

  mutating func ifExistsClause() throws(DBError) -> Bool {
    if matchKeyword("IF") {
      try expectKeyword("EXISTS")
      return true
    }
    return false
  }

  // MARK: - Expressions (precedence climbing)

  mutating func expression() throws(DBError) -> SQLExpr {
    try enterExprNesting()
    defer { exprDepth -= 1 }
    return try binaryExpr(0)
  }

  /// Operand at comparison precedence — for BETWEEN bounds and LIKE patterns.
  mutating func comparisonPrecOperand() throws(DBError) -> SQLExpr {
    try binaryExpr(Self.bpComparison)
  }

  // Left binding powers (higher binds tighter); the equality band groups the
  // suffix operators at one level, mirroring SQLite's precedence.
  static let bpOr = 10, bpAnd = 20, bpEquality = 30, bpComparison = 40
  static let bpAdditive = 50, bpMultiplicative = 60, bpConcat = 70, bpCollate = 80

  /// Binding power of the current token as an infix/postfix operator, or nil.
  /// Pure peek — consumes nothing.
  func infixBP() -> Int? {
    if checkKeyword("COLLATE") { return Self.bpCollate }
    if checkSymbol("||") { return Self.bpConcat }
    if checkSymbol("*") || checkSymbol("/") || checkSymbol("%") { return Self.bpMultiplicative }
    if checkSymbol("+") || checkSymbol("-") { return Self.bpAdditive }
    if checkSymbol("<") || checkSymbol("<=") || checkSymbol(">") || checkSymbol(">=") {
      return Self.bpComparison
    }
    if checkSymbol("=") || checkSymbol("==") || checkSymbol("!=") || checkSymbol("<>") {
      return Self.bpEquality
    }
    if checkKeyword("IS") || checkKeyword("IN") || checkKeyword("BETWEEN") || checkKeyword("LIKE")
      || checkKeyword("MATCH") || checkKeyword("GLOB") || checkKeyword("REGEXP") {
      return Self.bpEquality
    }
    if checkKeyword("NOT"),
      checkKeyword("IN", 1) || checkKeyword("LIKE", 1) || checkKeyword("BETWEEN", 1) {
      return Self.bpEquality
    }
    if checkKeyword("AND") { return Self.bpAnd }
    if checkKeyword("OR") { return Self.bpOr }
    return nil
  }

  /// Precedence-climbing (Pratt) expression parser: one loop over a flat
  /// binding-power table, replacing the former 12-function recursive chain. A
  /// run of same-precedence operators (`a OP b OP c …`) is a loop, and right-
  /// operand recursion is bounded by the number of precedence levels, not by
  /// expression length — so each nesting level costs ~a third of the stack.
  mutating func binaryExpr(_ minBP: Int) throws(DBError) -> SQLExpr {
    var lhs = try prefixExpr()
    while let bp = infixBP(), bp >= minBP {
      switch bp {
      case Self.bpCollate:
        _ = matchKeyword("COLLATE")
        lhs = .collate(lhs, try collationName())
      case Self.bpEquality:
        lhs = try equalitySuffix(lhs)
      case Self.bpAnd:
        _ = matchKeyword("AND")
        lhs = .binary(.and, lhs, try binaryExpr(Self.bpAnd + 1))
      case Self.bpOr:
        _ = matchKeyword("OR")
        lhs = .binary(.or, lhs, try binaryExpr(Self.bpOr + 1))
      default:
        let op = try consumeSimpleBinary()
        lhs = .binary(op, lhs, try binaryExpr(bp + 1))
      }
    }
    return lhs
  }

  /// Comparison/arithmetic/concat operators (`<=`/`>=` before `<`/`>`).
  /// `=`/`!=`/`<>` belong to the equality band, handled by `equalitySuffix`.
  mutating func consumeSimpleBinary() throws(DBError) -> SQLBinaryOp {
    if matchSymbol("||") { return .concat }
    if matchSymbol("*") { return .multiply }
    if matchSymbol("/") { return .divide }
    if matchSymbol("%") { return .modulo }
    if matchSymbol("+") { return .add }
    if matchSymbol("-") { return .subtract }
    if matchSymbol("<=") { return .le }
    if matchSymbol(">=") { return .ge }
    if matchSymbol("<") { return .lt }
    if matchSymbol(">") { return .gt }
    throw DBError.sqlSyntax(message: "expected a binary operator", offset: current.offset)
  }

  /// The equality band: `= == != <>`, `IS [NOT] NULL`, `[NOT] IN/BETWEEN/LIKE`.
  mutating func equalitySuffix(_ lhs: SQLExpr) throws(DBError) -> SQLExpr {
    if matchKeyword("MATCH") { return .binary(.match, lhs, try binaryExpr(Self.bpComparison)) }
    if checkKeyword("GLOB") || checkKeyword("REGEXP") { throw DBError.sqlUnsupported("GLOB/REGEXP") }
    if matchSymbol("=") || matchSymbol("==") {
      return .binary(.eq, lhs, try binaryExpr(Self.bpComparison))
    }
    if matchSymbol("!=") || matchSymbol("<>") {
      return .binary(.ne, lhs, try binaryExpr(Self.bpComparison))
    }
    if matchKeyword("IS") {
      let negated = matchKeyword("NOT")
      if matchKeyword("NULL") { return .isNull(lhs, negated: negated) }
      throw DBError.sqlUnsupported("IS comparisons other than IS [NOT] NULL")
    }
    if checkKeyword("NOT"),
      checkKeyword("IN", 1) || checkKeyword("LIKE", 1) || checkKeyword("BETWEEN", 1) {
      pos += 1
      if matchKeyword("IN") { return try inSuffix(lhs, negated: true) }
      if matchKeyword("BETWEEN") { return try betweenSuffix(lhs, negated: true) }
      try expectKeyword("LIKE")
      return .like(lhs, pattern: try comparisonPrecOperand(), negated: true)
    }
    if matchKeyword("IN") { return try inSuffix(lhs, negated: false) }
    if matchKeyword("BETWEEN") { return try betweenSuffix(lhs, negated: false) }
    if matchKeyword("LIKE") {
      let pattern = try comparisonPrecOperand()
      if checkKeyword("ESCAPE") { throw DBError.sqlUnsupported("LIKE ... ESCAPE") }
      return .like(lhs, pattern: pattern, negated: false)
    }
    throw DBError.sqlSyntax(message: "expected a comparison operator", offset: current.offset)
  }

  /// Prefix operators: `NOT` (loose — operand at equality precedence) and unary
  /// `-`/`+` (tight), with the numeric-literal folding the grammar requires.
  mutating func prefixExpr() throws(DBError) -> SQLExpr {
    if matchKeyword("NOT") {
      return .unary(.not, try binaryExpr(Self.bpEquality))
    }
    if matchSymbol("-") {
      if case .integer(let v) = current.kind { pos += 1; return .literal(.integer(0 &- v)) }
      if case .real(let d) = current.kind { pos += 1; return .literal(.real(-d)) }
      if case .bigInteger(let text) = current.kind {
        pos += 1
        if let v = Int64("-" + text) { return .literal(.integer(v)) }
        return .literal(.real(-(Double(text) ?? 0)))
      }
      return .unary(.negate, try prefixExpr())
    }
    if matchSymbol("+") { return try prefixExpr() }
    return try primary()
  }

  /// `x BETWEEN a AND b` desugars to `x>=a AND x<=b` (and NOT BETWEEN to
  /// `x<a OR x>b`), so the planner's range extraction treats it as a sargable
  /// range and 3VL on NULL matches SQLite. `a`/`b` parse at comparison
  /// precedence; the BETWEEN `AND` is consumed here, not by the boolean AND.
  mutating func betweenSuffix(_ subject: SQLExpr, negated: Bool) throws(DBError) -> SQLExpr {
    let lower = try comparisonPrecOperand()
    try expectKeyword("AND")
    let upper = try comparisonPrecOperand()
    if negated {
      return .binary(.or, .binary(.lt, subject, lower), .binary(.gt, subject, upper))
    }
    return .binary(.and, .binary(.ge, subject, lower), .binary(.le, subject, upper))
  }

  mutating func inSuffix(_ lhs: SQLExpr, negated: Bool) throws(DBError) -> SQLExpr {
    try expectSymbol("(")
    if checkKeyword("SELECT") {
      // Contracted shape: SELECT <ident> FROM json_each(<expr>)
      try expectKeyword("SELECT")
      _ = try identifier("column")
      try expectKeyword("FROM")
      let fn = try identifier("table function")
      guard fn.lowercased() == "json_each" else {
        throw DBError.sqlUnsupported("IN (SELECT ...) beyond json_each")
      }
      try expectSymbol("(")
      let source = try expression()
      try expectSymbol(")")
      try expectSymbol(")")
      return .inJSONEach(lhs, source: source, negated: negated)
    }
    var items: [SQLExpr] = []
    if !checkSymbol(")") {
      repeat {
        items.append(try expression())
      } while matchSymbol(",")
    }
    try expectSymbol(")")
    return .inList(lhs, items, negated: negated)
  }

  mutating func primary() throws(DBError) -> SQLExpr {
    let token = current
    switch token.kind {
    case .integer(let v):
      pos += 1
      return .literal(.integer(v))
    case .real(let d):
      pos += 1
      return .literal(.real(d))
    case .bigInteger(let text):
      pos += 1
      return .literal(.real(Double(text) ?? 0))
    case .string(let s):
      pos += 1
      return .literal(.text(s))
    case .blob(let bytes):
      pos += 1
      return .literal(.blob(bytes))
    case .parameter(let param):
      pos += 1
      return .parameter(param, offset: token.offset)
    case .keyword("NULL"):
      pos += 1
      return .literal(.null)
    case .keyword("CASE"):
      pos += 1
      return try caseExpr()
    case .keyword("CAST"):
      pos += 1
      try expectSymbol("(")
      let inner = try expression()
      try expectKeyword("AS")
      let type = try columnType()
      try expectSymbol(")")
      return .cast(inner, type)
    case .keyword("EXISTS"):
      throw DBError.sqlUnsupported("EXISTS subqueries")
    case .symbol("("):
      pos += 1
      if checkKeyword("SELECT") {
        let sub = try select()
        try expectSymbol(")")
        return .scalarSubquery(sub)
      }
      let inner = try expression()
      try expectSymbol(")")
      return inner
    case .identifier(let name):
      // function call?
      if case .symbol("(") = tokens[pos + 1].kind {
        pos += 2
        return try functionCall(name: name, offset: token.offset)
      }
      pos += 1
      if matchSymbol(".") {
        let column = try identifier("column name")
        return .column(table: name, name: column, offset: token.offset)
      }
      return .column(table: nil, name: name, offset: token.offset)
    case .keyword(let kw) where identifierKeywords.contains(kw):
      pos += 1
      if matchSymbol(".") {
        let column = try identifier("column name")
        return .column(table: kw.lowercased(), name: column, offset: token.offset)
      }
      return .column(table: nil, name: kw.lowercased(), offset: token.offset)
    default:
      throw DBError.sqlSyntax(message: "expected an expression", offset: token.offset)
    }
  }

  mutating func caseExpr() throws(DBError) -> SQLExpr {
    var operand: SQLExpr?
    if !checkKeyword("WHEN") {
      operand = try expression()
    }
    var whens: [SQLWhen] = []
    while matchKeyword("WHEN") {
      let condition = try expression()
      try expectKeyword("THEN")
      whens.append(SQLWhen(condition: condition, result: try expression()))
    }
    guard !whens.isEmpty else {
      throw DBError.sqlSyntax(message: "CASE requires at least one WHEN", offset: current.offset)
    }
    let elseExpr = matchKeyword("ELSE") ? try expression() : nil
    try expectKeyword("END")
    return .caseWhen(operand: operand, whens: whens, elseExpr: elseExpr)
  }

  mutating func functionCall(name: String, offset: Int) throws(DBError) -> SQLExpr {
    let upper = name.uppercased()
    let unsupportedAggregates: Set<String> = ["AVG", "MIN", "MAX", "TOTAL", "GROUP_CONCAT"]
    if unsupportedAggregates.contains(upper) {
      throw DBError.sqlUnsupported("\(upper)() aggregate")
    }
    // `bm25(tbl, w0, …)` parses as an ordinary function call; the binder (F4b)
    // rewrites it to a read of the FTS table's `rank` score slot.
    var star = false
    var args: [SQLExpr] = []
    if matchSymbol("*") {
      star = true
    } else if !checkSymbol(")") {
      if matchKeyword("DISTINCT") {
        throw DBError.sqlUnsupported("\(upper)(DISTINCT ...)")
      }
      repeat {
        args.append(try expression())
      } while matchSymbol(",")
    }
    try expectSymbol(")")
    if checkKeyword("OVER") { throw DBError.sqlUnsupported("window functions") }
    return .function(name: upper, args: args, star: star, offset: offset)
  }
}
