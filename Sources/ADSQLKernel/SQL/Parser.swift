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
                case .symbol("*") = tokens[pos + 2].kind
            {
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
                    || checkKeyword("CROSS")
                {
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

}
