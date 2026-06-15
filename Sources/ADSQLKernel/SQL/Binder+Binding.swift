/// Binding & plan-rewriting transforms for `Binder` (RFC 0009 H2/R4 — split from
/// Binder.swift). The helpers that rewrite a bound plan's access / trailing /
/// aggregate parts to slot-resolved column references, strip WHERE conjuncts the
/// access path already covers, derive join equalities and their below-the-join
/// references, expand `*` outputs, rewrite aggregate calls, and resolve output
/// names + collations. An `enum Binder` extension; code motion + the
/// compiler-demanded private->internal promotions.
extension Binder {
    static func bindAccess(_ access: AccessPlan, _ binding: QueryBinding) -> AccessPlan {
        switch access {
        case .tableScan:
            return .tableScan
        case .rowid(let exprs):
            return .rowid(exprs.map { bindColumnsNoWeights($0, binding) })
        case .index(let name, let probes, let constraint, let covering):
            let bound = probes.map { probe in
                IndexProbe(
                    equality: probe.equality.map { bindColumnsNoWeights($0, binding) },
                    trailing: probe.trailing.map { bindTrailing($0, binding) })
            }
            return .index(name: name, probes: bound, constraint: constraint, covering: covering)
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

    static func bindAggregate(_ spec: AggregateSpec, _ binding: QueryBinding) -> AggregateSpec {
        switch spec.kind {
        case .countStar: return spec
        case .count(let expr): return AggregateSpec(kind: .count(bindColumnsNoWeights(expr, binding)))
        case .sum(let expr): return AggregateSpec(kind: .sum(bindColumnsNoWeights(expr, binding)))
        case .jsonGroupArray(let expr):
            return AggregateSpec(kind: .jsonGroupArray(bindColumnsNoWeights(expr, binding)))
        case .jsonGroupObject(let name, let value):
            return AggregateSpec(
                kind: .jsonGroupObject(
                    name: bindColumnsNoWeights(name, binding),
                    value: bindColumnsNoWeights(value, binding)))
        }
    }

    /// WHERE with `covered` top-level conjuncts removed (nil if none remain).
    /// The covered nodes are the exact AST nodes the planner consumed, so `==`
    /// matches them.
    static func removeCovered(_ expr: SQLExpr?, _ covered: [SQLExpr]) -> SQLExpr? {
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
    static func joinEqualities(
        _ on: SQLExpr, binding: QueryBinding, innerDepth: Int
    ) -> [(column: Int, value: SQLExpr, source: SQLExpr)] {
        func conj(_ e: SQLExpr) -> [SQLExpr] {
            if case .binary(.and, let l, let r) = e { return conj(l) + conj(r) }
            return [e]
        }
        var out: [(column: Int, value: SQLExpr, source: SQLExpr)] = []
        for clause in conj(on) {
            guard case .binary(.eq, let lhs, let rhs) = clause else { continue }
            if let column = innerColumn(lhs, binding: binding, depth: innerDepth),
                referencesOnlyBelow(rhs, depth: innerDepth, binding: binding)
            {
                out.append((column, rhs, clause))
            } else if let column = innerColumn(rhs, binding: binding, depth: innerDepth),
                referencesOnlyBelow(lhs, depth: innerDepth, binding: binding)
            {
                out.append((column, lhs, clause))
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

    static func appendAllColumns(_ table: TableBinding, to outputs: inout [BoundOutput]) {
        for name in table.columnNames {
            outputs.append(
                BoundOutput(name: name, expr: .column(table: table.binding, name: name, offset: 0)))
        }
    }

    private static let aggregateNames: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "TOTAL", "GROUP_CONCAT",
        "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT",
    ]

    /// Replaces aggregate calls with `aggregateResult(slot)` references,
    /// collecting the distinct specs. Recurses through scalar expressions (so
    /// `COALESCE(SUM(x), 0)` works) but leaves subqueries — a different scope —
    /// untouched.
    static func rewriteAggregates(
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
                case "JSON_GROUP_ARRAY":
                    guard !star, args.count == 1 else {
                        throw DBError.sqlUnsupported("json_group_array(value)")
                    }
                    return slot(AggregateSpec(kind: .jsonGroupArray(args[0])))
                case "JSON_GROUP_OBJECT":
                    guard !star, args.count == 2 else {
                        throw DBError.sqlUnsupported("json_group_object(name, value)")
                    }
                    return slot(AggregateSpec(kind: .jsonGroupObject(name: args[0], value: args[1])))
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
    static func outputName(_ expr: SQLExpr, alias: String?, sourceText: String) -> String {
        if let alias { return alias }
        if case .column(_, let name, _) = expr { return name }
        return sourceText
    }

    /// Collation of an expression for ORDER BY / DISTINCT: explicit COLLATE
    /// wins, else the referenced column's declared collation, else BINARY.
    static func collation(of expr: SQLExpr, binding: QueryBinding) -> Collation {
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
