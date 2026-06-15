/// Result-assembly pipeline for `SelectExecutor` (RFC 0009 H2/R4 — split from
/// Executor.swift). The per-row evaluation context (`RowContext`/`rowEnv` and the
/// correlated-subquery guard), compound (UNION/UNION ALL) finalization, the
/// post-scan DISTINCT dedup + reference analysis, ORDER BY sort, and LIMIT/OFFSET
/// slicing — i.e. everything that shapes the materialized rows after the access
/// path produces them. `SelectExecutor` statics in an extension; pure code motion
/// + visibility (no behaviour change).
extension SelectExecutor {
    // MARK: - Compounds (UNION / UNION ALL)

    /// First-occurrence dedup of complete result rows under per-column
    /// collations (UNION semantics), via the canonical group key.
    static func distinctRows(_ rows: [[Value]], collations: [Collation]) -> [[Value]] {
        var seen = Set<GroupKey>()
        var out: [[Value]] = []
        out.reserveCapacity(rows.count)
        for row in rows where seen.insert(GroupKey(row, collations: collations)).inserted {
            out.append(row)
        }
        return out
    }

    /// Applies a compound's ORDER BY (by result-column index) and LIMIT/OFFSET
    /// to the combined rows, then wraps them with the shared header.
    static func finishCompound(
        _ rows: [[Value]], compound: BoundCompound, params: SQLParameters
    ) throws(DBError) -> [SQLRow] {
        var result = rows
        if !compound.order.isEmpty {
            let terms = compound.order
            let permutation = result.indices.sorted { lhs, rhs in
                for term in terms {
                    let comparison = orderCompare(result[lhs][term.index], result[rhs][term.index], term.collation)
                    if comparison != 0 { return term.descending ? comparison > 0 : comparison < 0 }
                }
                return lhs < rhs
            }
            result = permutation.map { result[$0] }
        }
        if compound.limit != nil || compound.offset != nil {
            let env = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
            // Cap so `lower + limit` below can't overflow (Swift `+` traps).
            let bound = Int.max / 4
            var offset = 0
            if let offsetExpr = compound.offset, let value = try boundValue(offsetExpr, env), value > 0 {
                offset = min(Int(clamping: value), bound)
            }
            var limit: Int?
            if let limitExpr = compound.limit, let value = try boundValue(limitExpr, env), value >= 0 {
                limit = min(Int(clamping: value), bound)
            }
            let lower = min(offset, result.count)
            let upper = limit.map { min(lower + $0, result.count) } ?? result.count
            result = Array(result[lower..<upper])
        }
        return result.map { SQLRow(header: compound.header, values: $0) }
    }

    // MARK: - Evaluation environment

    /// The live row for each table in a query, with per-table null-extension for
    /// LEFT joins. Column reads route here through the binding's resolver.
    final class RowContext {
        let slots: [RowSlot]
        var nullExtended: [Bool]
        /// Resolved join-key indexes for an eligible 2-table merge join (set by
        /// `runJoin`/`runAggregated` from the plan's `mergePlan`); `runMergeJoin` uses
        /// them under `.merge`/`.auto`. nil ⇒ not merge-eligible.
        var mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)?

        init(definitions: [TableDefinition]) {
            self.slots = definitions.map { RowSlot(table: $0) }
            self.nullExtended = Array(repeating: false, count: definitions.count)
        }

        func load(
            _ table: Int, rowid: Int64, span: UnsafeRawBufferPointer, score: Double = 0,
            coveringIncludes: [String]? = nil
        ) {
            nullExtended[table] = false
            unsafe slots[table].load(
                rowid: rowid, span: span, score: score, coveringIncludes: coveringIncludes)
        }
        /// Loads a materialized (span-less) row into a table slot — the hash-join
        /// build side re-serving a decoded row during probe.
        func loadMaterialized(_ table: Int, rowid: Int64, values: [Value]) {
            nullExtended[table] = false
            slots[table].loadMaterialized(rowid: rowid, values: values)
        }
        func setNull(_ table: Int) { nullExtended[table] = true }

        func value(table: Int, column: Int) throws(DBError) -> Value {
            nullExtended[table] ? .null : try slots[table].value(at: column)
        }
    }

    /// Runs a correlated scalar subquery against the current outer row; provided
    /// by the statement layer (which has transaction/schema access).
    typealias SubqueryRunner =
        (SQLSelect, RowContext, QueryBinding) throws(DBError) -> Value

    static func rejectSubquery(
        _: SQLSelect, _: RowContext, _: QueryBinding
    ) throws(DBError) -> Value {
        throw DBError.sqlUnsupported("subquery in this context")
    }

    static func rowEnv(
        _ plan: BoundSelect, context: RowContext, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)?,
        subquery: @escaping SubqueryRunner
    ) -> SQLEvalEnv {
        let binding = plan.binding
        return SQLEvalEnv(
            parameter: { parameter throws(DBError) in try params.lookup(parameter) },
            column: { (qualifier, name, _) throws(DBError) in
                // The subquery's own tables first, then the correlated outer row.
                if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
                    return try context.value(table: table, column: column)
                }
                if let outer, let (table, column) = outer.binding.resolve(qualifier: qualifier, name: name) {
                    return try outer.context.value(table: table, column: column)
                }
                throw DBError.noSuchColumn(table: qualifier ?? binding.tables[0].table, column: name)
            },
            collationOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnCollations[$0.column] }
            },
            columnTypeOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnTypes[$0.column] }
            },
            // Bind-time-resolved slots: read the row directly, no name resolution.
            // Always an inner reference (correlated outer refs stay `.column`).
            boundColumn: { (table, column) throws(DBError) in
                try context.value(table: table, column: column)
            },
            boundCollation: { (table, column) in binding.tables[table].columnCollations[column] },
            boundColumnType: { (table, column) in binding.tables[table].columnTypes[column] },
            scalarSubquery: { sub throws(DBError) in try subquery(sub, context, binding) })
    }

    // MARK: - DISTINCT

    /// First-occurrence dedup under `=` semantics (numeric classes unify, the
    /// same comparison ORDER BY uses) via the canonical `GroupKey` — O(n), the
    /// hashing shared with GROUP BY/UNION (`distinctRows`). `GroupKey`
    /// canonicalization (integral REAL→INTEGER, NOCASE fold) matches the
    /// `orderCompare` equality this used to scan for.
    static func deduplicate(
        _ rows: [[Value]], sortKeys: [[Value]], ordered: Bool, collations: [Collation]
    ) -> (rows: [[Value]], sortKeys: [[Value]]) {
        var seen = Set<GroupKey>()
        seen.reserveCapacity(rows.count)
        var keptRows: [[Value]] = []
        var keptKeys: [[Value]] = []
        for (index, row) in rows.enumerated()
        where seen.insert(GroupKey(row, collations: collations)).inserted {
            keptRows.append(row)
            if ordered { keptKeys.append(sortKeys[index]) }
        }
        return (keptRows, keptKeys)
    }

    /// True when `orderBy` ranks the leading FTS table's bm25 `rank` slot ascending
    /// (best/most-negative first), optionally followed by the FTS rowid ascending —
    /// i.e. `ORDER BY rank` or `ORDER BY bm25(…), rowid`. This is the only shape
    /// routed to the F6c WAND path: its score-then-smallest-rowid tiebreak matches
    /// the heap's, so WAND returns the identical top-k. Any other ordering (DESC, a
    /// non-rank leading key, a different trailing tiebreak) returns false and keeps
    /// score-all.
    static func isFTSRankAscendingOrder(_ orderBy: [SQLOrderingTerm]) -> Bool {
        guard let first = orderBy.first, !first.descending,
            case .boundColumn(let table, let column) = first.expr,
            table == 0, column == ftsRankSlot
        else { return false }
        switch orderBy.count {
        case 1:
            return true
        case 2:
            // A trailing rowid-ascending tiebreak (FTS rowid alias is slot 0).
            guard !orderBy[1].descending, case .boundColumn(let t, let c) = orderBy[1].expr else {
                return false
            }
            return t == 0 && c == 0
        default:
            return false
        }
    }

    /// True when `e` (or any sub-expression) reads bound column `(table, column)`.
    /// Used to decide whether an FTS query needs per-doc bm25 scoring (F6e): a
    /// membership-only MATCH never reads the `rank` slot, so scoring is dead work.
    /// A scalar subquery is treated conservatively (assume the score may be read).
    static func exprReferences(_ e: SQLExpr, table: Int, column: Int) -> Bool {
        switch e {
        case .boundColumn(let t, let c): return t == table && c == column
        case .literal, .column, .parameter, .aggregateResult: return false
        case .binary(_, let l, let r):
            return exprReferences(l, table: table, column: column)
                || exprReferences(r, table: table, column: column)
        case .unary(_, let x), .cast(let x, _), .collate(let x, _):
            return exprReferences(x, table: table, column: column)
        case .like(let x, let p, _):
            return exprReferences(x, table: table, column: column)
                || exprReferences(p, table: table, column: column)
        case .isNull(let x, _):
            return exprReferences(x, table: table, column: column)
        case .inList(let x, let list, _):
            return exprReferences(x, table: table, column: column)
                || list.contains { exprReferences($0, table: table, column: column) }
        case .inJSONEach(let x, let s, _):
            return exprReferences(x, table: table, column: column)
                || exprReferences(s, table: table, column: column)
        case .caseWhen(let op, let whens, let elseExpr):
            if let op, exprReferences(op, table: table, column: column) { return true }
            if whens.contains(where: {
                exprReferences($0.condition, table: table, column: column)
                    || exprReferences($0.result, table: table, column: column)
            }) {
                return true
            }
            if let elseExpr { return exprReferences(elseExpr, table: table, column: column) }
            return false
        case .function(_, let args, _, _):
            return args.contains { exprReferences($0, table: table, column: column) }
        case .scalarSubquery:
            return true
        }
    }

    // MARK: - ORDER BY

    /// A stable sort permutation: ties (including the pre-sort order) keep input
    /// order so equal rows are deterministic.
    static func sortedOrder(
        _ keys: [[Value]], terms: [SQLOrderingTerm], collations: [Collation]
    ) -> [Int] {
        keys.indices.sorted { lhs, rhs in
            for position in terms.indices {
                let comparison = orderCompare(keys[lhs][position], keys[rhs][position], collations[position])
                if comparison != 0 {
                    return terms[position].descending ? comparison > 0 : comparison < 0
                }
            }
            return lhs < rhs  // stable
        }
    }

    /// ORDER BY / DISTINCT comparison: NULL sorts first (ASC), then SQLite's
    /// cross-class numeric comparison.
    static func orderCompare(_ a: Value, _ b: Value, _ collation: Collation) -> Int {
        switch (a.isNull, b.isNull) {
        case (true, true): return 0
        case (true, false): return -1
        case (false, true): return 1
        case (false, false): return SQLCompare.compare(a, b, collation: collation) ?? 0
        }
    }

    // MARK: - LIMIT / OFFSET

    static func sliceBounds(
        _ plan: BoundSelect, params: SQLParameters
    ) throws(DBError) -> (offset: Int, limit: Int?)? {
        guard plan.limit != nil || plan.offset != nil else { return nil }
        let env = SQLEvalEnv.parametersOnly { parameter throws(DBError) in try params.lookup(parameter) }

        // Cap each at Int.max/4 so downstream `offset + limit` / `lower + limit`
        // additions can never overflow (Swift `+` traps on overflow). The cap is
        // ~2.3×10^18 — unbounded for any real dataset, so behavior is unchanged.
        let bound = Int.max / 4
        var limit: Int?
        if let limitExpr = plan.limit {
            // SQLite: NULL or negative LIMIT means unbounded.
            if let value = try boundValue(limitExpr, env), value >= 0 {
                limit = min(Int(clamping: value), bound)
            } else {
                limit = nil
            }
        }
        var offset = 0
        if let offsetExpr = plan.offset {
            if let value = try boundValue(offsetExpr, env), value > 0 {
                offset = min(Int(clamping: value), bound)
            }
        }
        return (offset, limit)
    }

    /// Integer coercion for LIMIT/OFFSET (SQLite casts to integer; NULL → nil).
    private static func boundValue(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Int64? {
        switch SQLFunctions.cast(try SQLEval.evaluate(expr, env), to: .integer) {
        case .integer(let value): return value
        default: return nil
        }
    }
}
