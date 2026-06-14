/// Access-path probe evaluation + type-boundary coercion for `SelectExecutor`
/// (RFC 0009 H2/R4 — split from Executor.swift). Turns a WHERE's equality/range
/// constraints into rowid lists and index `IndexBounds` (`evaluateRowids`,
/// `buildIndexBounds`), coercing each probe value to the indexed column's storage
/// class with SQLite's boundary rules (`coerceEquality`/`coerceBound`). `SelectExecutor`
/// statics in an extension; pure code motion + visibility.
extension SelectExecutor {
    static func evaluateRowids(
        _ exprs: [SQLExpr], _ env: SQLEvalEnv
    ) throws(DBError) -> [Int64] {
        var rowids: [Int64] = []
        var seen = Set<Int64>()
        for expr in exprs {
            let value = try SQLEval.evaluate(expr, env)
            let rowid: Int64?
            switch value {
            case .integer(let v): rowid = v
            case .real(let d) where d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18:
                rowid = Int64(d)
            default: rowid = nil  // a non-integral rowid matches no row
            }
            if let rowid, seen.insert(rowid).inserted { rowids.append(rowid) }
        }
        return rowids
    }

    enum BuiltBounds {
        case scan  // probe value could not be converted; fall back
        case bounds([IndexBounds])  // empty probes already dropped
    }

    static func buildIndexBounds(
        _ probes: [IndexProbe], index: Catalog.IndexRecord, table: Catalog.TableRecord,
        env: SQLEvalEnv
    ) throws(DBError) -> BuiltBounds {
        let columns = index.definition.columns.compactMap { table.definition.columnIndex(of: $0) }
        guard columns.count == index.definition.columns.count else { return .scan }
        let types = columns.map { table.definition.columns[$0].type }

        var built: [IndexBounds] = []
        for probe in probes {
            var equalityValues: [Value] = []
            var empty = false
            for (position, expr) in probe.equality.enumerated() {
                switch coerceEquality(try SQLEval.evaluate(expr, env), to: types[position]) {
                case .use(let value): equalityValues.append(value)
                case .empty: empty = true
                case .giveUp: return .scan
                }
                if empty { break }
            }
            if empty { continue }

            guard let trailing = probe.trailing else {
                built.append(.prefix(equalityValues))
                continue
            }
            let rangeType = types[equalityValues.count]
            switch trailing {
            case .range(let lower, let upper):
                let lowerBound = try coerceBound(lower, to: rangeType, env: env)
                let upperBound = try coerceBound(upper, to: rangeType, env: env)
                let lowerList = lowerBound.map { equalityValues + [$0.value] } ?? equalityValues
                let upperList = upperBound.map { equalityValues + [$0.value] } ?? equalityValues
                built.append(
                    .range(
                        lower: lowerList, upper: upperList,
                        lowerOpen: lowerBound.map { !$0.inclusive } ?? false,
                        upperOpen: upperBound.map { !$0.inclusive } ?? false))
            }
        }
        return .bounds(built)
    }

    private enum Coerced {
        case use(Value)
        case empty  // distinct storage classes never compare equal: no rows
        case giveUp  // unsafe to convert (e.g. inexact int→real): fall back to scan
    }

    /// An equality probe value coerced to a column's strict class.
    private static func coerceEquality(_ value: Value, to type: ColumnType) -> Coerced {
        if value.columnType == type { return .use(value) }
        switch type {
        case .integer:
            if case .real(let d) = value {
                if d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18 {
                    return .use(.integer(Int64(d)))
                }
                return .empty  // no integer equals a non-integral real
            }
            return .empty
        case .real:
            if case .integer(let i) = value {
                if let d = Double(exactly: i) { return .use(.real(d)) }
                return .giveUp  // |i| > 2^53: converting could match the wrong real
            }
            return .empty
        case .text, .blob:
            return .empty
        }
    }

    /// A range bound applies to the index only when it matches the column's
    /// class; otherwise the bound is dropped (that side stays unbounded) and the
    /// residual WHERE enforces it.
    private static func coerceBound(
        _ bound: BoundExpr?, to type: ColumnType, env: SQLEvalEnv
    ) throws(DBError) -> (value: Value, inclusive: Bool)? {
        guard let bound else { return nil }
        let value = try SQLEval.evaluate(bound.expr, env)
        guard value.columnType == type else { return nil }
        return (value, bound.inclusive)
    }
}
