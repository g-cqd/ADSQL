/// Join execution for `SelectExecutor` (RFC 0009 H2/R4 — split from the
/// 1551-line Executor.swift). The right-recursive nested-loop driver
/// (`forEachFilteredRow`/`runJoin`) with LEFT null-extension and ON/WHERE
/// placement, plus the hash and merge equi-join fast paths and their
/// probe-key/existence/COUNT helpers. These are `SelectExecutor` statics kept in
/// an extension beside the scan core they reuse (`forEachRow`, `resolveSource`,
/// `RowContext`, `Accumulator`, `RowSource`), which the split promoted from
/// `private` to `internal`. Behaviour is unchanged — pure code motion + visibility.
extension SelectExecutor {
    /// Visits every post-WHERE composite row, loading `context` so `body` can
    /// read columns through the binding. Single-table queries scan the access
    /// path; joins drive a right-recursive nested loop — ON filters during
    /// matching, WHERE applies at the leaf (after any LEFT null-extension), and
    /// LEFT emits one null-extended row when the right side has no match.
    static func forEachFilteredRow<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
        joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
        resolver: R, context: RowContext, env: SQLEvalEnv, paramsEnv: SQLEvalEnv,
        execution: ExecutionOptions = .default,
        _ body: () throws(DBError) -> Void
    ) throws(DBError) {
        func passesWhere() throws(DBError) -> Bool {
            guard let predicate = plan.whereExpr else { return true }
            return SQLEval.truth(try SQLEval.evaluate(predicate, env)) == .yes
        }

        guard plan.isJoin else {
            let source = try resolveSource(
                plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
            // F4 index-only: when the source is a covering scan, decode slot 0 through
            // the INCLUDE layout. Currently the binder only marks non-aggregated single-
            // table plans covering (those run via `SelectExecutor.run`, not here), so
            // this stays nil on the aggregate path that reaches `forEachFilteredRow`;
            // honoring it regardless keeps this path correct if that ever changes.
            let covering: [String]? = {
                if case .index(_, _, let includes) = source { return includes }
                return nil
            }()
            unsafe try forEachRow(source, table: tables[0], resolver: resolver) {
                rowid, span, score throws(DBError) in
                unsafe context.load(
                    0, rowid: rowid, span: span, score: score, coveringIncludes: covering)
                if try passesWhere() { try body() }
                return true
            }
            return
        }

        // Merge join (existence/COUNT fast path), and the plan `.auto` chooses when
        // eligible: it is unconditionally cheaper than the nested loop here (one ordered
        // index pass vs M per-outer probes), so the cost choice is just "merge if
        // eligible". `.auto` falls through to the nested loop when ineligible; hash is
        // not auto-selected (it loses on the symmetric self-join — finding #1 — pending
        // a build-side cost estimate). Returns false when ineligible.
        if execution.join == .merge || execution.join == .auto,
            try runMergeJoin(
                plan, tables: tables, resolver: resolver, context: context,
                emit: { () throws(DBError) in if try passesWhere() { try body() } })
        {
            return
        }

        // Hash join (selected, eligible 2-table INNER equi-join): build the inner,
        // probe the outer — O(M+N), no per-outer index descent. Returns false when
        // ineligible, falling through to the nested-loop driver below.
        if execution.join == .hash,
            try runInnerHashJoin(
                plan, tables: tables, index: index, ftsRecords: ftsRecords, resolver: resolver,
                context: context, env: env, paramsEnv: paramsEnv,
                budgetBytes: execution.hashJoinMemoryBudgetBytes,
                emit: { () throws(DBError) in if try passesWhere() { try body() } })
        {
            return
        }

        // Reused across outer rows (and join depths — each `fastExistence` builds and
        // seeks before recursing, freeing it for the next depth). An empty span for
        // the defensive existence-hit load (the inner slot is never read).
        var probeKeyBuffer: [UInt8] = []
        probeKeyBuffer.reserveCapacity(64)
        let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)

        func descend(_ depth: Int) throws(DBError) {
            if depth == tables.count {
                if try passesWhere() { try body() }
                return
            }
            let join = plan.joins[depth - 1]
            let joinIndex = depth - 1 < joinIndexes.count ? joinIndexes[depth - 1] : nil
            // Fast existence: a UNIQUE-index full-key equality probe on an existence-only
            // inner reduces to one seek with a zero-copy key — no bounds, cursor, table
            // descent, or ON re-check. nil ⇒ ineligible → the general path below.
            if join.innerExistenceOnly, let joinIndex,
                let hit = try fastExistence(
                    join: join, index: joinIndex, table: tables[depth],
                    context: context, env: env, resolver: resolver, buffer: &probeKeyBuffer)
            {
                if hit {
                    unsafe context.load(depth, rowid: 0, span: emptySpan)
                    try descend(depth + 1)
                } else if join.kind == .left {
                    context.setNull(depth)
                    try descend(depth + 1)
                }
                return
            }
            var matched = false
            // Index-nested-loop: probe the inner table's index with the outer row's
            // value (a superset); the ON below is the residual. Falls back to a full
            // inner scan when `join.access` is `.tableScan`.
            // A missing index record (caller didn't resolve one) degrades an
            // `.index` probe to a scan; `.rowid` probes need no record.
            let innerSource = try resolveAccess(
                join.access, index: joinIndex, table: tables[depth], ftsRecords: ftsRecords, env: env)
            // Existence-only is sound only while the access stays an actual probe: an
            // unconvertible value degrades it to a full scan (a superset), which must
            // re-apply the ON. So gate on the *runtime* source, not just the plan flag.
            let existence: Bool
            switch innerSource {
            case .index, .rowids: existence = join.innerExistenceOnly
            case .table, .fts: existence = false
            }
            unsafe try forEachRow(
                innerSource, table: tables[depth], resolver: resolver, existenceOnly: existence
            ) {
                rowid, span, score throws(DBError) in
                unsafe context.load(depth, rowid: rowid, span: span, score: score)
                // Existence-only: the probe already enforces the whole ON and no inner
                // column is read, so skip the (empty-span) re-evaluation.
                if existence {
                    matched = true
                    try descend(depth + 1)
                } else if SQLEval.truth(try SQLEval.evaluate(join.on, env)) == .yes {
                    matched = true
                    try descend(depth + 1)
                }
                return true
            }
            if join.kind == .left && !matched {
                context.setNull(depth)
                try descend(depth + 1)
            }
        }

        let outerSource = try resolveSource(
            plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
        unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(0, rowid: rowid, span: span, score: score)
            try descend(1)
            return true
        }
    }

    /// Single-seek existence for a UNIQUE-index full-key equality probe on an
    /// existence-only join inner. Builds the probe key (zero-copy from the outer
    /// columns' page bytes where possible) into the reused `buffer`, then checks the
    /// index for a matching entry — no bounds, no `RowCursor`, no table descent.
    /// Returns nil when ineligible (caller uses the general path); `.some(hit)` when
    /// existence was resolved. UNIQUE-only: existence (descend once) preserves join
    /// cardinality, while non-unique fan-out keeps the enumerating existence path.
    private static func fastExistence<R: PageResolver>(
        join: BoundJoin, index: Catalog.IndexRecord, table: Catalog.TableRecord,
        context: RowContext, env: SQLEvalEnv, resolver: R, buffer: inout [UInt8]
    ) throws(DBError) -> Bool? {
        guard index.definition.unique,
            case .index(let name, let probes, _, _) = join.access,
            name == index.definition.name, probes.count == 1,
            probes[0].trailing == nil,
            probes[0].equality.count == index.definition.columns.count
        else { return nil }
        let tableColumns = index.definition.columns.compactMap { table.definition.columnIndex(of: $0) }
        guard tableColumns.count == index.definition.columns.count else { return nil }
        let collations = Relation.indexCollations(index.definition, table: table.definition)

        buffer.removeAll(keepingCapacity: true)
        for (position, expr) in probes[0].equality.enumerated() {
            let idxType = table.definition.columns[tableColumns[position]].type
            guard
                try appendProbeField(
                    expr, idxType: idxType, collation: collations[position],
                    context: context, env: env, into: &buffer)
            else { return nil }  // non-column / class mismatch / NULL / NaN → general path
        }

        var cursor = Cursor(resolver: resolver, tree: index.handle)
        let prefixLen = buffer.count
        // `withUnsafeBytes` is untyped-rethrows; capture into a `Result` (as
        // `Relation.firstRowid` does) to stay in `throws(DBError)`.
        var outcome: Result<Bool, DBError> = .success(false)
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            do throws(DBError) {
                _ = unsafe try cursor.seek(raw)
                guard cursor.isValid else { return }
                // A4: stored index keys are `columns ++ 8-byte rowid`, so `seek` never
                // reports an exact hit on the column prefix — verify the entry's prefix
                // equals the probe (UNIQUE ⇒ at most one such entry).
                outcome = .success(
                    unsafe try cursor.withCurrent { (key, _) throws(DBError) -> Bool in
                        guard key.count == prefixLen + 8 else { return false }
                        return unsafe raw.elementsEqual(UnsafeRawBufferPointer(rebasing: key[0..<prefixLen]))
                    } ?? false)
            } catch {
                outcome = .failure(error)
            }
        }
        return try outcome.get()
    }

    /// Encodes one equality-probe field into `buffer` directly from the outer
    /// column's bytes (TEXT/BLOB zero-copy; INTEGER/REAL from the cached value),
    /// byte-identical to `KeyCodec.append`. Returns false to fall back to the general
    /// (Value-coercing) path: a non-`.boundColumn` expr, an outer storage class that
    /// differs from the index column's, a null-extended outer, a NULL/absent value,
    /// or NaN.
    private static func appendProbeField(
        _ expr: SQLExpr, idxType: ColumnType, collation: Collation,
        context: RowContext, env: SQLEvalEnv, into buffer: inout [UInt8]
    ) throws(DBError) -> Bool {
        guard case .boundColumn(let outerTable, let outerCol) = expr,
            env.boundColumnType(outerTable, outerCol) == idxType,
            !context.nullExtended[outerTable]
        else { return false }
        let slot = context.slots[outerTable]
        switch idxType {
        case .text:
            return unsafe try slot.withTextBytes(at: outerCol) { bytes in
                guard let bytes = unsafe bytes else { return false }
                unsafe KeyCodec.appendTextBytes(bytes, collation: collation, to: &buffer)
                return true
            }
        case .blob:
            return unsafe try slot.withBlobBytes(at: outerCol) { bytes in
                guard let bytes = unsafe bytes else { return false }
                unsafe KeyCodec.appendBlobBytes(bytes, to: &buffer)
                return true
            }
        case .integer:
            guard case .integer(let value) = try slot.value(at: outerCol) else { return false }
            KeyCodec.appendInteger(value, to: &buffer)
            return true
        case .real:
            guard case .real(let value) = try slot.value(at: outerCol), !value.isNaN else { return false }
            try KeyCodec.appendReal(value, to: &buffer)
            return true
        }
    }

    /// Hash join for a 2-table INNER equi-join: builds a hash of the inner table
    /// keyed by the equi-join columns, then probes with each outer row — O(M+N), no
    /// per-outer index descent. Produces the same composite `RowContext` state as the
    /// nested loop, so `emit` (WHERE + projection/aggregation) is unchanged. Returns
    /// false when ineligible (not a single INNER join, no usable same-class/collation
    /// column equi key, or the build exceeds `budgetBytes`) → caller uses nested loop.
    ///
    /// Equi keys are extracted from the (already-bound) ON and key a `GroupKey`,
    /// whose equality matches SQL `=` for same-class/collation columns (no false
    /// negatives). Non-equi ON conjuncts are re-checked per match. A NULL probe key
    /// matches nothing (SQL `=` is unknown with NULL).
    private static func runInnerHashJoin<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
        ftsRecords: [String: Catalog.FTSRecord], resolver: R,
        context: RowContext, env: SQLEvalEnv, paramsEnv: SQLEvalEnv,
        budgetBytes: Int, emit: () throws(DBError) -> Void
    ) throws(DBError) -> Bool {
        guard plan.joins.count == 1, plan.joins[0].kind == .inner else { return false }
        let join = plan.joins[0]
        let innerDepth = join.table
        let binding = plan.binding

        var equiInner: [Int] = []
        var equiOuter: [SQLExpr] = []
        var equiCollations: [Collation] = []
        var residualConjuncts: [SQLExpr] = []
        for conjunct in andConjuncts(join.on) {
            if let key = hashEquiKey(conjunct, innerDepth: innerDepth, binding: binding) {
                equiInner.append(key.innerColumn)
                equiOuter.append(key.outerColumn)
                equiCollations.append(key.collation)
            } else {
                residualConjuncts.append(conjunct)
            }
        }
        guard !equiInner.isEmpty else { return false }
        let onResidual: SQLExpr? =
            residualConjuncts.isEmpty
            ? nil : residualConjuncts.dropFirst().reduce(residualConjuncts[0]) { .binary(.and, $0, $1) }

        // SEMI-JOIN: when the inner is existence-only (no inner column is read by the
        // query) and the ON is pure equi (no residual), the inner row *values* are never
        // needed — build per-key COUNTS instead of materializing every inner row, then
        // emit `count` times per matching outer. Avoids the O(inner-rows) materialization
        // that makes the plain hash the wrong tool for a large symmetric existence join
        // (findings #1/#3); cardinality is preserved (COUNT(*) = Σ matched run lengths).
        if join.innerExistenceOnly, onResidual == nil {
            var counts: [GroupKey: Int] = [:]
            unsafe try forEachRow(.table, table: tables[innerDepth], resolver: resolver) {
                rowid, span, score throws(DBError) in
                unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
                var keyValues: [Value] = []
                keyValues.reserveCapacity(equiInner.count)
                for column in equiInner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
                counts[GroupKey(keyValues, collations: equiCollations), default: 0] += 1
                return true
            }
            let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
            let outerSource = try resolveSource(
                plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
            unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
                rowid, span, score throws(DBError) in
                unsafe context.load(0, rowid: rowid, span: span, score: score)
                var probeValues: [Value] = []
                probeValues.reserveCapacity(equiOuter.count)
                for expr in equiOuter { probeValues.append(try SQLEval.evaluate(expr, env)) }
                if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
                guard let count = counts[GroupKey(probeValues, collations: equiCollations)] else { return true }
                unsafe context.load(innerDepth, rowid: 0, span: emptySpan)
                for _ in 0..<count { try emit() }
                return true
            }
            return true
        }

        // BUILD: full scan of the inner table → hash[inner equi key] = [(rowid, full row)].
        var hash: [GroupKey: [(rowid: Int64, values: [Value])]] = [:]
        var approxBytes = 0
        var overBudget = false
        let innerTable = tables[innerDepth]
        unsafe try forEachRow(.table, table: innerTable, resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
            var keyValues: [Value] = []
            keyValues.reserveCapacity(equiInner.count)
            for column in equiInner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
            let values = try context.slots[innerDepth].materialize()
            hash[GroupKey(keyValues, collations: equiCollations), default: []].append((rowid, values))
            approxBytes += 24 + values.count * 24
            if approxBytes > budgetBytes {
                overBudget = true
                return false
            }
            return true
        }
        if overBudget { return false }  // build emitted nothing → caller falls back to nested loop

        // PROBE: scan the outer (leading) source; look up each outer row's matches.
        let outerSource = try resolveSource(
            plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
        unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(0, rowid: rowid, span: span, score: score)
            var probeValues: [Value] = []
            probeValues.reserveCapacity(equiOuter.count)
            for expr in equiOuter { probeValues.append(try SQLEval.evaluate(expr, env)) }
            if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
            guard let matches = hash[GroupKey(probeValues, collations: equiCollations)] else { return true }
            for match in matches {
                context.loadMaterialized(innerDepth, rowid: match.rowid, values: match.values)
                if let onResidual, SQLEval.truth(try SQLEval.evaluate(onResidual, env)) != .yes { continue }
                try emit()
            }
            return true
        }
        return true
    }

    /// Merge-join existence/COUNT fast path (RFC 0009 H4/R2). A 2-table INNER
    /// existence equi-join whose join-key columns each have a UNIQUE, NOT-NULL,
    /// single-column index (the binder's `mergePlan`; indexes resolved into
    /// `context.mergeIndexes`) needs no per-outer probe: lock-step the two sorted
    /// indexes and emit once per key present on both sides (the intersection).
    /// UNIQUE + NOT-NULL rules out dup-run cross-products and NULL non-matches, so
    /// the result is provably identical to the nested loop. A self-join is the case
    /// where the two indexes coincide (the two cursors walk the same tree in step).
    /// Returns false (→ the proven nested-loop driver) outside this subset.
    private static func runMergeJoin<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord],
        resolver: R, context: RowContext, emit: () throws(DBError) -> Void
    ) throws(DBError) -> Bool {
        guard let indexes = context.mergeIndexes,
            plan.joins.count == 1, plan.joins[0].kind == .inner, plan.joins[0].innerExistenceOnly,
            plan.isAggregated, plan.whereExpr == nil,
            !plan.finalizationReferencedTables.contains(0),
            !plan.finalizationReferencedTables.contains(1)
        else { return false }

        // Neither table's columns are read (existence + COUNT(*)-style), so empty
        // spans suffice; two ordered cursors lock-step on the key prefix.
        let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
        unsafe context.load(0, rowid: 0, span: emptySpan)
        unsafe context.load(1, rowid: 0, span: emptySpan)
        var outer = Cursor(resolver: resolver, tree: indexes.outer.handle)
        var inner = Cursor(resolver: resolver, tree: indexes.inner.handle)
        var oValid = try outer.move(to: .first)
        var iValid = try inner.move(to: .first)
        while oValid, iValid {
            let cmp = try compareMergeKeyPrefixes(&outer, &inner)
            if cmp == 0 {
                try emit()
                oValid = try outer.next()
                iValid = try inner.next()
            } else if cmp < 0 {
                oValid = try outer.next()
            } else {
                iValid = try inner.next()
            }
        }
        return true
    }

    /// Compares the two cursors' current index keys by their column prefix — the
    /// bytes before the 8-byte rowid suffix (A4). Both cursors are valid.
    private static func compareMergeKeyPrefixes<R: PageResolver>(
        _ outer: inout Cursor<R>, _ inner: inout Cursor<R>
    ) throws(DBError) -> Int {
        var result = 0
        _ = unsafe try outer.withCurrent { (oKey, _) throws(DBError) -> Bool in
            let oPrefix = unsafe UnsafeRawBufferPointer(rebasing: oKey[0..<(oKey.count - 8)])
            _ = unsafe try inner.withCurrent { (iKey, _) throws(DBError) -> Bool in
                let iPrefix = unsafe UnsafeRawBufferPointer(rebasing: iKey[0..<(iKey.count - 8)])
                result = unsafe Node.compare(oPrefix, iPrefix)
                return true
            }
            return true
        }
        return result
    }

    private static func andConjuncts(_ expr: SQLExpr) -> [SQLExpr] {
        if case .binary(.and, let l, let r) = expr { return andConjuncts(l) + andConjuncts(r) }
        return [expr]
    }

    /// A hashable equi-join conjunct `inner.col = outer.col` (either operand order)
    /// where both are bound columns of the SAME storage class and collation — so a
    /// `GroupKey` match equals SQL `=` (no affinity coercion). nil otherwise.
    private static func hashEquiKey(
        _ conjunct: SQLExpr, innerDepth: Int, binding: QueryBinding
    ) -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)? {
        guard case .binary(.eq, let lhs, let rhs) = conjunct else { return nil }
        func pair(
            _ innerSide: SQLExpr, _ outerSide: SQLExpr
        )
            -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)?
        {
            guard case .boundColumn(let it, let ic) = innerSide, it == innerDepth,
                case .boundColumn(let ot, let oc) = outerSide, ot < innerDepth,
                binding.tables[it].columnTypes[ic] == binding.tables[ot].columnTypes[oc],
                binding.tables[it].columnCollations[ic] == binding.tables[ot].columnCollations[oc]
            else { return nil }
            return (ic, outerSide, binding.tables[it].columnCollations[ic])
        }
        return pair(lhs, rhs) ?? pair(rhs, lhs)
    }

    static func runJoin<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
        joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
        resolver: R, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
        execution: ExecutionOptions = .default,
        mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil
    ) throws(DBError) -> [SQLRow] {
        let context = RowContext(definitions: tables.map(\.definition))
        context.mergeIndexes = mergeIndexes
        let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
        let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
        let collectKeys = !plan.orderBy.isEmpty
        let bounds = try sliceBounds(plan, params: params)

        // Bounded top-N: an ORDER BY + small positive LIMIT (no DISTINCT) keeps only
        // `offset+limit` rows in a sorted buffer during the scan instead of
        // materializing and sorting every matched row — and projects the full output
        // tuple ONLY for rows that make the cut (the dominant cost on the apple-docs
        // `/search` join, RFC 0010: thousands of FTS matches but LIMIT 20). The keep
        // rule, tie-break (insert-after-equal ⇒ scan order), and final slice are
        // byte-identical to the collect-all + `sortedOrder` + `sliceBounds` path below
        // (`sortedOrder` is stable on `lhs < rhs`, and the FTS docid set arrives in
        // ascending rowid order, so equal-key runs keep the same order either way).
        // DISTINCT is excluded: dedup must see the whole set before LIMIT, so a row
        // outside the top-N keys could still be a needed unique representative.
        if collectKeys, !plan.distinct, let bounds, let limit = bounds.limit, limit >= 1 {
            let bound = bounds.offset + limit
            if bound >= 1, bound <= 4096 {
                var buffer = TopNBuffer(
                    capacity: bound, terms: plan.orderBy, collations: plan.orderCollations)
                try forEachFilteredRow(
                    plan, tables: tables, index: index, joinIndexes: joinIndexes,
                    ftsRecords: ftsRecords, resolver: resolver, context: context, env: env,
                    paramsEnv: paramsEnv, execution: execution
                ) { () throws(DBError) in
                    var keys: [Value] = []
                    keys.reserveCapacity(plan.orderBy.count)
                    for term in plan.orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
                    // Only project the full tuple when the row qualifies for the buffer.
                    if buffer.wouldDrop(keys) { return }
                    var projected: [Value] = []
                    projected.reserveCapacity(plan.outputs.count)
                    for output in plan.outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
                    buffer.insert(keys: keys, row: projected)
                }
                let kept = buffer.sortedRows()
                let lower = min(bounds.offset, kept.count)
                return kept[lower...].map { SQLRow(header: plan.header, values: $0) }
            }
        }

        var rows: [[Value]] = []
        var sortKeys: [[Value]] = []
        try forEachFilteredRow(
            plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
            resolver: resolver, context: context, env: env, paramsEnv: paramsEnv, execution: execution
        ) { () throws(DBError) in
            var projected: [Value] = []
            projected.reserveCapacity(plan.outputs.count)
            for output in plan.outputs { projected.append(try SQLEval.evaluate(output.expr, env)) }
            rows.append(projected)
            if collectKeys {
                var keys: [Value] = []
                for term in plan.orderBy { keys.append(try SQLEval.evaluate(term.expr, env)) }
                sortKeys.append(keys)
            }
        }

        if plan.distinct {
            (rows, sortKeys) = deduplicate(
                rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
        }
        if collectKeys {
            let order = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
            rows = order.map { rows[$0] }
        }
        if let bounds {
            let lower = min(bounds.offset, rows.count)
            let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
            rows = Array(rows[lower..<upper])
        }
        return rows.map { SQLRow(header: plan.header, values: $0) }
    }
}

/// A fixed-capacity ascending top-N buffer for the join path: holds the best
/// `capacity` rows seen so far, ordered by `terms`/`collations`. The keep rule,
/// the insert-after-equal tie-break (so an equal-key run keeps scan order), and
/// the eventual `sortedRows()` order are identical to the single-table
/// `SelectExecutor.Accumulator` top-N and the collect-all `sortedOrder` path — so
/// substituting it never changes results, only how many rows are projected/kept.
struct TopNBuffer {
    private let capacity: Int
    private let terms: [SQLOrderingTerm]
    private let collations: [Collation]
    private var rows: [[Value]] = []
    private var keys: [[Value]] = []

    init(capacity: Int, terms: [SQLOrderingTerm], collations: [Collation]) {
        self.capacity = capacity
        self.terms = terms
        self.collations = collations
        rows.reserveCapacity(capacity)
        keys.reserveCapacity(capacity)
    }

    /// True when the buffer is full and `candidate` does NOT order before the worst
    /// kept key — the row would be dropped, so the caller can skip projecting it.
    func wouldDrop(_ candidate: [Value]) -> Bool {
        rows.count >= capacity && !orderBefore(candidate, keys[capacity - 1])
    }

    /// Inserts a qualifying row into the sorted buffer, evicting the worst when over
    /// capacity. (Call only when `wouldDrop` is false.)
    mutating func insert(keys candidate: [Value], row: [Value]) {
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            // Upper bound: an equal key inserts AFTER existing entries, so a run of
            // tied sort keys keeps scan order (ascending rowid) — matching the
            // collect-all `sortedOrder` (stable) and the single-table top-N.
            if orderBefore(candidate, keys[mid]) { hi = mid } else { lo = mid + 1 }
        }
        rows.insert(row, at: lo)
        keys.insert(candidate, at: lo)
        if rows.count > capacity {
            rows.removeLast()
            keys.removeLast()
        }
    }

    /// The kept rows in ascending ORDER BY order (already maintained sorted).
    consuming func sortedRows() -> [[Value]] { rows }

    /// Does sort key `a` order strictly before `b` under the ORDER BY terms?
    private func orderBefore(_ a: [Value], _ b: [Value]) -> Bool {
        for position in terms.indices {
            let comparison = SelectExecutor.orderCompare(a[position], b[position], collations[position])
            if comparison != 0 { return terms[position].descending ? comparison > 0 : comparison < 0 }
        }
        return false
    }
}
