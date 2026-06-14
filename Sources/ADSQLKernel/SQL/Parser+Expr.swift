/// Expression parsing for `SQLParser` (RFC 0009 H2/R4 — split from Parser.swift).
/// The precedence-climbing expression grammar: `expression` down through binary
/// binding power, the BETWEEN/IN/LIKE/IS equality suffixes, prefix/unary, the
/// primaries (literals, columns, parenthesised, subqueries), CASE, and function
/// calls. An `extension SQLParser`; pure code motion (all members are internal).
extension SQLParser {
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
            || checkKeyword("MATCH") || checkKeyword("GLOB") || checkKeyword("REGEXP")
        {
            return Self.bpEquality
        }
        if checkKeyword("NOT"),
            checkKeyword("IN", 1) || checkKeyword("LIKE", 1) || checkKeyword("BETWEEN", 1)
        {
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
            checkKeyword("IN", 1) || checkKeyword("LIKE", 1) || checkKeyword("BETWEEN", 1)
        {
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
            if case .integer(let v) = current.kind {
                pos += 1
                return .literal(.integer(0 &- v))
            }
            if case .real(let d) = current.kind {
                pos += 1
                return .literal(.real(-d))
            }
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
