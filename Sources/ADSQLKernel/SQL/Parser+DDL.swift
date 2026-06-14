/// DDL parsing for `SQLParser` (RFC 0009 H2/R4 — split from Parser.swift).
/// CREATE (TABLE / INDEX / VIRTUAL TABLE / TRIGGER) and DROP: the column +
/// constraint + table-body grammar, column types and DEFAULT / REFERENCES
/// clauses, FTS5 virtual-table options, trigger bodies, and IF [NOT] EXISTS. An
/// `extension SQLParser`; pure code motion (all members are internal).
extension SQLParser {
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
            return .createIndex(
                SQLCreateIndex(
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
            content =
                contentValue.isEmpty
                ? .contentless(deleteEnabled: contentlessDelete)
                : .external(table: contentValue, rowid: contentRowid ?? "rowid")
        } else {
            content = .selfContained
        }
        return .createVirtualTable(
            SQLCreateVirtualTable(
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
        let endOffset = current.offset + 3  // "END" is 3 bytes regardless of case
        _ = advance()  // consume END

        let sql = sourceText(from: startOffset, to: endOffset)
        return .createTrigger(
            SQLCreateTrigger(
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
        var pkColumns: [String]?  // table-level PRIMARY KEY(...)

        repeat {
            if checkKeyword("PRIMARY") || checkKeyword("UNIQUE") || checkKeyword("CHECK")
                || checkKeyword("FOREIGN")
            {
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
                    _ = try expression()  // parsed, discarded
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
        if matchKeyword("STRICT") {}  // engine is strict regardless
        if matchKeyword("WITHOUT") { throw DBError.sqlUnsupported("WITHOUT ROWID tables") }

        // Resolve table-level PK.
        if let pkColumns {
            if pkColumns.count == 1,
                let index = columns.firstIndex(where: { $0.name == pkColumns[0] }),
                columns[index].type == .integer,
                case .implicitRowid = primaryKey
            {
                primaryKey = .rowidAlias(column: pkColumns[0], autoincrement: false)
            } else {
                uniqueColumnSets.insert(pkColumns, at: 0)
                for column in pkColumns {
                    if let index = columns.firstIndex(where: { $0.name == column }) {
                        columns[index].notNull = true  // SQLite PKs are NOT NULL
                    }
                }
            }
        }

        var implied: [IndexDefinition] = []
        for (n, cols) in uniqueColumnSets.enumerated() {
            implied.append(
                IndexDefinition(
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
                args == [.literal(.text("now"))]
            {
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
            _ = try identifier("parent column")  // must be the rowid alias; name discarded
            try expectSymbol(")")
        }
        var action: FKAction = .restrict  // SQLite default NO ACTION ≈ restrict-on-delete here
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
}
