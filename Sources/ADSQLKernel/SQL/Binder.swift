/// The binder: turns a parsed `SQLSelect` into a `BoundSelect`/`BoundQuery`
/// (the abstract syntax resolved against a concrete schema version), including
/// access selection, join-equality analysis, aggregate rewriting, and column
/// binding. The bound-plan data types it produces live in `Plan.swift`.
enum Binder {
    /// Binds a top-level query: a single SELECT or a compound. The trailing
    /// ORDER BY/LIMIT/OFFSET on a compound belong to the whole result, so the
    /// first arm is bound without them.
    static func bindQuery(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundQuery {
        guard !select.compounds.isEmpty else {
            return .select(try bindSelect(select, schema: schema))
        }
        var firstArm = select
        firstArm.compounds = []
        firstArm.orderBy = []
        firstArm.limit = nil
        firstArm.offset = nil
        var arms: [BoundCompound.Arm] = [
            BoundCompound.Arm(op: nil, select: try bindSelect(firstArm, schema: schema))
        ]
        for compound in select.compounds {
            arms.append(
                BoundCompound.Arm(op: compound.op, select: try bindSelect(compound.select, schema: schema)))
        }
        let width = arms[0].select.outputs.count
        for arm in arms where arm.select.outputs.count != width {
            throw DBError.sqlBind("SELECTs to the left and right of a compound have different column counts")
        }
        let first = arms[0].select
        var order: [BoundCompound.CompoundOrder] = []
        for term in select.orderBy {
            order.append(
                try resolveCompoundOrder(term, outputs: first.outputs, collations: first.outputCollations))
        }
        return .compound(
            BoundCompound(
                arms: arms, header: first.header, outputCollations: first.outputCollations,
                order: order, limit: select.limit, offset: select.offset))
    }

    /// A compound ORDER BY term references a result column by 1-based position
    /// or by name (SQLite restriction).
    private static func resolveCompoundOrder(
        _ term: SQLOrderingTerm, outputs: [BoundOutput], collations: [Collation]
    ) throws(DBError) -> BoundCompound.CompoundOrder {
        var expr = term.expr
        var explicit: Collation?
        if case .collate(let inner, let collation) = expr {
            expr = inner
            explicit = collation
        }
        let index: Int
        switch expr {
        case .literal(.integer(let position)):
            guard position >= 1, position <= outputs.count else {
                throw DBError.sqlBind("ORDER BY position \(position) is out of range")
            }
            index = Int(position) - 1
        case .column(nil, let name, _):
            guard let match = outputs.firstIndex(where: { $0.name.lowercased() == name.lowercased() })
            else {
                throw DBError.sqlBind("ORDER BY \(name) is not a column of the compound result")
            }
            index = match
        default:
            throw DBError.sqlUnsupported("compound ORDER BY must name a result column or position")
        }
        return BoundCompound.CompoundOrder(
            index: index, descending: term.descending, collation: explicit ?? collations[index])
    }

    static func bindSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
        guard let from = select.from else {
            throw DBError.sqlUnsupported("SELECT without FROM (arrives in a later slice)")
        }

        // Resolve every table in FROM/JOIN order; the first is the outer table. An
        // FTS5 virtual table isn't in `schema.tables`; it binds against a synthetic
        // rowid-alias definition (its only queryable column is `rowid`; the indexed
        // text is reached through MATCH, not column reads).
        func bind(_ reference: SQLTableRef) throws(DBError) -> TableBinding {
            if let definition = schema.tables[reference.name] {
                return TableBinding(reference: reference, definition: definition)
            }
            if schema.ftsTables[reference.name] != nil {
                return TableBinding(
                    reference: reference, definition: syntheticFTSDefinition(reference.name), isFTS: true)
            }
            throw DBError.noSuchTable(reference.name)
        }
        var tables: [TableBinding] = [try bind(from)]
        var rawJoins: [(kind: SQLJoinKind, depth: Int, on: SQLExpr)] = []
        for join in select.joins {
            tables.append(try bind(join.table))
            rawJoins.append((join.kind, tables.count - 1, join.on))
        }
        let binding = QueryBinding(tables: tables)

        // Index-nested-loop access per inner table: each ON conjunct of the form
        // `inner.col = <expr over outer tables>` is a *necessary* match condition,
        // so probing it is a valid superset (ON is re-applied at the leaf). Falls
        // back to a full inner scan when no such equality hits an indexed column.
        var joins: [BoundJoin] = []
        // Whether each join's access is an exact-equality probe that covers its
        // *entire* ON predicate — the bind-time half of the existence-only test
        // (completed in the final pass once column references are known).
        var joinProbeCoversON: [Bool] = []
        for raw in rawJoins {
            let inner = tables[raw.depth]
            // An FTS inner table has no schema table/indexes; its access comes from a
            // MATCH conjunct on its ON clause, so pass the synthetic definition and no
            // indexes (the planner extracts `.fts` from the MATCH, not from indexes).
            let innerDefinition =
                inner.isFTS ? syntheticFTSDefinition(inner.table) : schema.tables[inner.table]!
            let innerIndexes = inner.isFTS ? [] : schema.indexes(on: inner.table)
            let equalities = joinEqualities(raw.on, binding: binding, innerDepth: raw.depth)
            let (access, covered) = Planner.planJoin(
                equalities: equalities, inner: inner, on: raw.on, binding: binding, innerDepth: raw.depth,
                indexes: innerIndexes, definition: innerDefinition)
            // A MATCH conjunct the `.fts` access consumes is an access path, never a
            // row predicate, so drop it from the ON clause re-applied during matching
            // (evaluating `.binary(.match,…)` at a row is a runtime error).
            var on = raw.on
            if case .fts = access, let (_, conjunct) = Planner.ftsMatchConjunct(raw.on, source: inner) {
                on = removeCovered(raw.on, [conjunct]) ?? .literal(.integer(1))
            }
            // An exact-equality probe (`.rowid`, or `.index` with no trailing range)
            // whose covered conjuncts are the whole ON means the probe alone enforces
            // the join — the executor can skip the ON re-check (and, if the inner is
            // otherwise unreferenced, the table descent entirely).
            joinProbeCoversON.append(isExactEquality(access) && removeCovered(raw.on, covered) == nil)
            joins.append(
                BoundJoin(kind: raw.kind, table: raw.depth, on: on, access: access, innerExistenceOnly: false))
        }

        // Aggregate calls in outputs/HAVING/ORDER BY are rewritten to slot
        // references; `aggregates` collects the distinct ones to accumulate.
        var aggregates: [AggregateSpec] = []
        var outputs: [BoundOutput] = []
        for column in select.columns {
            switch column {
            case .star:
                for table in tables { appendAllColumns(table, to: &outputs) }
            case .tableStar(let qualifier):
                guard let table = tables.first(where: { $0.binding == qualifier.lowercased() }) else {
                    throw DBError.sqlBind("no such table alias: \(qualifier)")
                }
                appendAllColumns(table, to: &outputs)
            case .expr(let expr, let alias, let sourceText):
                let rewritten = try rewriteAggregates(expr, into: &aggregates)
                outputs.append(
                    BoundOutput(name: outputName(expr, alias: alias, sourceText: sourceText), expr: rewritten))
            }
        }
        var having: SQLExpr?
        if let rawHaving = select.having {
            having = try rewriteAggregates(rawHaving, into: &aggregates)
        }
        // ORDER BY resolves a bare identifier against output aliases first (SQLite
        // behavior), so `... score*2 AS s ORDER BY s` sorts by the expression.
        var orderBy = select.orderBy
        for index in orderBy.indices {
            if case .column(nil, let name, _) = orderBy[index].expr,
                let match = outputs.first(where: { $0.name.lowercased() == name.lowercased() })
            {
                orderBy[index].expr = match.expr  // already aggregate-rewritten
            } else {
                orderBy[index].expr = try rewriteAggregates(orderBy[index].expr, into: &aggregates)
            }
        }
        let isAggregated = !select.groupBy.isEmpty || !aggregates.isEmpty

        let orderCollations = orderBy.map { collation(of: $0.expr, binding: binding) }
        let outputCollations = outputs.map { collation(of: $0.expr, binding: binding) }
        let groupCollations = select.groupBy.map { collation(of: $0, binding: binding) }
        let header = SQLColumnHeader(outputs.map(\.name))
        // The planner optimizes the outer table only: column-vs-constant conjuncts
        // on it (join predicates are column-vs-column, hence ignored here and left
        // to the residual). For a LEFT join the outer side is never null-extended,
        // so pushing its WHERE conjuncts down stays a valid superset. Aggregated
        // queries scan every row, so the planner's order claims don't apply.
        let source = tables[0]
        // A leading FTS table has no schema table/indexes; its access is the `.fts`
        // path the planner extracts from a `f MATCH '…'` WHERE conjunct (synthetic
        // definition, no indexes — MATCH drives the source, columns don't).
        let sourceDefinition =
            source.isFTS ? syntheticFTSDefinition(source.table) : schema.tables[source.table]!
        let sourceIndexes = source.isFTS ? [] : schema.indexes(on: source.table)
        let planning = Planner.plan(
            where: select.whereExpr, orderBy: select.orderBy, source: source,
            indexes: sourceIndexes, definition: sourceDefinition)
        let yieldsOrder = joins.isEmpty && !isAggregated
        // A leading-FTS MATCH conjunct is an access path the `.fts` source consumes,
        // never a row predicate — strip it from the base WHERE used as the leaf
        // residual on *every* path (join/aggregate included), or evaluating
        // `.binary(.match,…)` per row would be a runtime error.
        var whereExpr = select.whereExpr
        if case .fts = planning.plan {
            whereExpr = removeCovered(whereExpr, planning.coveredConjuncts)
        }
        // Residual elimination applies to the single-table path only (the join/
        // aggregate paths evaluate the full WHERE at the leaf).
        let residualWithoutCovered =
            yieldsOrder
            ? removeCovered(whereExpr, planning.coveredConjuncts)
            : whereExpr

        // Final step: resolve every runtime column reference to (table, column)
        // slots so the evaluator never re-resolves names per row. Runs after all
        // bind-time analysis (planning, collation, INLJ extraction, removeCovered),
        // which consumed the `.column` form. Correlated outer refs that don't
        // resolve here stay `.column` (runtime outer fallback).
        //
        // The same pass intercepts `bm25(tbl, w0, w1, …)` (and bare `rank`), which
        // reads the FTS `rank` score slot: it rewrites the call to a bound read of
        // that slot and records the per-column weights for the table, so they can be
        // threaded into the `.fts` access plan below (one ranking per FTS table).
        var ftsWeights: [Int: [Double]] = [:]
        func bind(_ expr: SQLExpr) -> SQLExpr { bindColumns(expr, binding, &ftsWeights) }
        let boundOutputs = outputs.map { BoundOutput(name: $0.name, expr: bind($0.expr)) }
        let boundWhere = whereExpr.map(bind)
        let boundResidual = residualWithoutCovered.map(bind)
        let boundOrderBy = orderBy.map { SQLOrderingTerm(expr: bind($0.expr), descending: $0.descending) }
        let boundGroupBy = select.groupBy.map(bind)
        let boundHaving = having.map(bind)
        let boundAggregates = aggregates.map { bindAggregate($0, binding) }
        let boundJoinsOn = joins.map { bind($0.on) }
        let mergePlan = mergeJoinPlan(joins: joins, boundOn: boundJoinsOn, binding: binding, schema: schema)
        // Apply the captured weights now that every expression has been bound (so a
        // bm25() anywhere in the projection/ORDER BY is seen). Default to all-ones
        // for a plain `rank` reference (the table index is the leading table or the
        // join depth).
        var leadingAccess = bindAccess(applyWeights(planning.plan, ftsWeights, depth: 0), binding)
        let boundJoinAccess = joins.map {
            bindAccess(applyWeights($0.access, ftsWeights, depth: $0.table), binding)
        }

        // Column-reference analysis (drives the existence-only join inner and the
        // aggregate materialization guard). `alwaysRefs` are tables whose real row
        // bytes are read during the scan (projection / WHERE / HAVING / ORDER BY /
        // GROUP BY / aggregates / any access-path probe value). An unresolved
        // `.column` (correlated) or a scalar subquery sets `unknownRefs`, which
        // conservatively disables every elision.
        var alwaysRefs: Set<Int> = []
        var unknownRefs = false
        for o in boundOutputs { collectTableRefs(o.expr, into: &alwaysRefs, unknown: &unknownRefs) }
        if let w = boundWhere { collectTableRefs(w, into: &alwaysRefs, unknown: &unknownRefs) }
        if let h = boundHaving { collectTableRefs(h, into: &alwaysRefs, unknown: &unknownRefs) }
        for t in boundOrderBy { collectTableRefs(t.expr, into: &alwaysRefs, unknown: &unknownRefs) }
        for g in boundGroupBy { collectTableRefs(g, into: &alwaysRefs, unknown: &unknownRefs) }
        for spec in boundAggregates {
            switch spec.kind {
            case .countStar: break
            case .count(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
            case .sum(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
            case .jsonGroupArray(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
            case .jsonGroupObject(let name, let value):
                collectTableRefs(name, into: &alwaysRefs, unknown: &unknownRefs)
                collectTableRefs(value, into: &alwaysRefs, unknown: &unknownRefs)
            }
        }
        collectAccessRefs(leadingAccess, into: &alwaysRefs, unknown: &unknownRefs)
        for acc in boundJoinAccess { collectAccessRefs(acc, into: &alwaysRefs, unknown: &unknownRefs) }
        // Per-join ON references; a join other than d may read d's columns.
        var onRefs: [Set<Int>] = []
        for on in boundJoinsOn {
            var refs: Set<Int> = []
            collectTableRefs(on, into: &refs, unknown: &unknownRefs)
            onRefs.append(refs)
        }
        // Existence-only iff the probe covers the whole ON (bind-time) AND no other
        // expression — including any *other* join's ON — reads this inner table.
        let existenceOnly: [Bool] = joins.indices.map { d in
            guard !unknownRefs, joinProbeCoversON[d] else { return false }
            let table = joins[d].table
            if alwaysRefs.contains(table) { return false }
            for e in joins.indices where e != d && onRefs[e].contains(table) { return false }
            return true
        }
        // Tables whose group representative is read at finalization (outputs /
        // HAVING / ORDER BY). Existence-only tables are guaranteed absent.
        var finalRefs: Set<Int> = []
        var finalUnknown = false
        for o in boundOutputs { collectTableRefs(o.expr, into: &finalRefs, unknown: &finalUnknown) }
        if let h = boundHaving { collectTableRefs(h, into: &finalRefs, unknown: &finalUnknown) }
        for t in boundOrderBy { collectTableRefs(t.expr, into: &finalRefs, unknown: &finalUnknown) }
        let finalizationReferenced: Set<Int> =
            finalUnknown ? Set(tables.indices) : finalRefs

        // F4 — covering / INCLUDE-index serving: if the chosen leading access is an
        // index scan and EVERY base-table column this query still needs is served by
        // that index — the rowid-alias (read from the key) or an INCLUDE column (read
        // from the entry value) — serve rows index-only, with no descent into the base
        // row. Gated to the non-aggregated, single-table path (the only one routed
        // through `SelectExecutor.run`'s covering-aware accumulator) and disabled on
        // any unresolved/correlated reference. `requiredColumns` is computed from the
        // BOUND expressions, so it cannot miss a referenced column (see below).
        if !isAggregated, joins.isEmpty, !unknownRefs,
            case .index(let name, _, _, _) = leadingAccess,
            let definition = sourceIndexes.first(where: { $0.name == name })
        {
            // Columns of table 0 the executor must still read from a row at the leaf.
            // Sources, exhaustively:
            //   • projection outputs — always read;
            //   • the RESIDUAL WHERE (`boundResidual`), NOT the full WHERE: the dropped
            //     conjuncts are exact equalities the index probe enforces by position
            //     (`col = const`), so their column is never read from a row — only the
            //     constant the cursor was seeked to. (`boundResidual` == the residual
            //     here: this branch is gated to the single-table path where the binder
            //     applied `removeCovered`.) Using the residual is what lets the canonical
            //     `SELECT c,d FROM t WHERE a=?` (with `a` a key column) be covering;
            //   • HAVING / ORDER BY / GROUP BY — read during sort/group;
            //   • the access probe values — constants/parameters in practice, folded in
            //     defensively so a future probe shape cannot under-count.
            // Every source is a *bound* expression, so a base-table reference appears as
            // `.boundColumn(0, c)` this collector sees; an unresolved `.column` would
            // have set `unknownRefs` and disabled the whole branch. This is why the set
            // CANNOT under-count: if any column read at runtime were missed, it would be
            // a `.boundColumn` the exhaustive walk skipped — which it does not.
            var requiredColumns: Set<Int> = []
            var requiredUnknown = false
            func need(_ e: SQLExpr) {
                collectColumnRefs(e, table: 0, into: &requiredColumns, unknown: &requiredUnknown)
            }
            for o in boundOutputs { need(o.expr) }
            if let r = boundResidual { need(r) }
            if let h = boundHaving { need(h) }
            for t in boundOrderBy { need(t.expr) }
            for g in boundGroupBy { need(g) }
            collectColumnRefs(forAccess: leadingAccess, table: 0, into: &requiredColumns, unknown: &requiredUnknown)

            // The set this index can serve index-only: the rowid-alias plus every
            // INCLUDE column. A non-rowid KEY column is NOT included — the entry value
            // stores only INCLUDE columns, so `RowSlot`/`RowView` cannot decode a key
            // column from it (a key column can never also be an INCLUDE; the index
            // definition forbids it). This is stricter than `key ∪ includes`, which is
            // unsound for the present storage layout — correctness over optimization.
            var servable: Set<Int> = []
            if let alias = source.rowidAliasIndex { servable.insert(alias) }
            for column in definition.includes {
                if let index = source.columnIndex(qualifier: nil, name: column) { servable.insert(index) }
            }
            if !requiredUnknown, requiredColumns.isSubset(of: servable) {
                leadingAccess = coveringRewrite(leadingAccess, includes: definition.includes)
            }
        }

        // Index-ordered DISTINCT: a single-table `SELECT DISTINCT <plain cols>` with
        // no WHERE/ORDER BY/aggregate can scan an index whose key columns are exactly
        // those outputs, decoding each distinct key prefix — no table descent, no
        // dedup set. Excludes NOCASE-text columns (case is folded into the key, so it
        // can't reconstruct the original value); those fall back to streaming dedup.
        var distinctIndexName: String?
        if select.distinct, !isAggregated, joins.isEmpty, !source.isFTS,
            select.whereExpr == nil, select.orderBy.isEmpty
        {
            var columnNames: [String] = []
            var eligible = true
            for out in outputs {
                guard case .column(let qualifier, let name, _) = out.expr,
                    let column = source.columnIndex(qualifier: qualifier, name: name)
                else {
                    eligible = false
                    break
                }
                if source.columnTypes[column] == .text, source.columnCollations[column] == .nocase {
                    eligible = false  // NOCASE text decodes to folded bytes, not the original
                    break
                }
                columnNames.append(name)
            }
            if eligible, !columnNames.isEmpty {
                for candidate in sourceIndexes
                where candidate.columns.count == columnNames.count
                    && zip(candidate.columns, columnNames).allSatisfy({
                        $0.lowercased() == $1.lowercased()
                    })
                {
                    distinctIndexName = candidate.name
                    break
                }
            }
        }

        return BoundSelect(
            binding: binding,
            joins: joins.indices.map { d in
                BoundJoin(
                    kind: joins[d].kind, table: joins[d].table, on: boundJoinsOn[d],
                    access: boundJoinAccess[d], innerExistenceOnly: existenceOnly[d])
            },
            outputs: boundOutputs,
            outputCollations: outputCollations,
            whereExpr: boundWhere,
            residualWithoutCovered: boundResidual,
            orderBy: boundOrderBy,
            orderCollations: orderCollations,
            groupBy: boundGroupBy,
            groupCollations: groupCollations,
            having: boundHaving,
            aggregates: boundAggregates,
            isAggregated: isAggregated,
            distinct: select.distinct,
            limit: select.limit,
            offset: select.offset,
            header: header,
            access: leadingAccess,
            accessYieldsOrder: yieldsOrder && planning.yieldsOrder,
            rowidOrderSatisfiesOrderBy: yieldsOrder && planning.rowidOrderSatisfiesOrderBy,
            finalizationReferencedTables: finalizationReferenced,
            distinctIndexName: distinctIndexName,
            mergePlan: mergePlan)
    }

    /// A 2-table INNER equi-join whose join-key columns each have a UNIQUE,
    /// NOT-NULL, single-column index of the same collation → merge-eligible (the
    /// executor lock-steps the two sorted indexes under `.merge`/`.auto`). nil
    /// otherwise (the proven nested-loop / hash paths handle every other shape).
    private static func mergeJoinPlan(
        joins: [BoundJoin], boundOn: [SQLExpr], binding: QueryBinding, schema: Schema
    ) -> MergePlan? {
        guard joins.count == 1, joins[0].kind == .inner, binding.tables.count == 2,
            !binding.tables[0].isFTS, !binding.tables[1].isFTS,
            case .binary(.eq, let lhs, let rhs) = boundOn[0]
        else { return nil }
        func cols(_ a: SQLExpr, _ b: SQLExpr) -> (outer: Int, inner: Int)? {
            guard case .boundColumn(let at, let ac) = a, case .boundColumn(let bt, let bc) = b,
                at == 0, bt == 1
            else { return nil }
            return (ac, bc)
        }
        guard let (oc, ic) = cols(lhs, rhs) ?? cols(rhs, lhs),
            binding.tables[0].columnCollations[oc] == binding.tables[1].columnCollations[ic],
            let outerIndex = uniqueKeyIndex(binding.tables[0], column: oc, schema: schema),
            let innerIndex = uniqueKeyIndex(binding.tables[1], column: ic, schema: schema)
        else { return nil }
        return MergePlan(
            outerIndex: outerIndex, innerIndex: innerIndex, outerColumn: oc, innerColumn: ic)
    }

    /// The name of a UNIQUE, single-column index on `column` of `table` whose
    /// column is NOT NULL (so no NULL keys break the merge lock-step), else nil.
    private static func uniqueKeyIndex(
        _ table: TableBinding, column: Int, schema: Schema
    ) -> String? {
        guard let definition = schema.tables[table.table], column < definition.columns.count,
            definition.columns[column].notNull
        else { return nil }
        let columnName = table.columnNames[column].lowercased()
        for index in schema.indexes(on: table.table)
        where index.unique && index.columns.count == 1
            && index.columns[0].lowercased() == columnName
        {
            return index.name
        }
        return nil
    }

    /// Adds the `(table)` of every `.boundColumn` in `expr` to `refs`. Sets
    /// `unknown` for an unresolved/correlated `.column` or a scalar subquery, whose
    /// reachable columns can't be determined here (callers then disable the
    /// reference-driven elisions). Covers every `SQLExpr` case.
    private static func collectTableRefs(
        _ expr: SQLExpr, into refs: inout Set<Int>, unknown: inout Bool
    ) {
        switch expr {
        case .boundColumn(let table, _):
            refs.insert(table)
        case .column, .scalarSubquery:
            unknown = true
        case .literal, .parameter, .aggregateResult:
            break
        case .binary(_, let l, let r):
            collectTableRefs(l, into: &refs, unknown: &unknown)
            collectTableRefs(r, into: &refs, unknown: &unknown)
        case .unary(_, let i), .cast(let i, _), .collate(let i, _):
            collectTableRefs(i, into: &refs, unknown: &unknown)
        case .isNull(let i, _):
            collectTableRefs(i, into: &refs, unknown: &unknown)
        case .like(let s, let p, _):
            collectTableRefs(s, into: &refs, unknown: &unknown)
            collectTableRefs(p, into: &refs, unknown: &unknown)
        case .inList(let s, let items, _):
            collectTableRefs(s, into: &refs, unknown: &unknown)
            for item in items { collectTableRefs(item, into: &refs, unknown: &unknown) }
        case .inJSONEach(let s, let src, _):
            collectTableRefs(s, into: &refs, unknown: &unknown)
            collectTableRefs(src, into: &refs, unknown: &unknown)
        case .caseWhen(let operand, let whens, let elseExpr):
            if let operand { collectTableRefs(operand, into: &refs, unknown: &unknown) }
            for when in whens {
                collectTableRefs(when.condition, into: &refs, unknown: &unknown)
                collectTableRefs(when.result, into: &refs, unknown: &unknown)
            }
            if let elseExpr { collectTableRefs(elseExpr, into: &refs, unknown: &unknown) }
        case .function(_, let args, _, _):
            for arg in args { collectTableRefs(arg, into: &refs, unknown: &unknown) }
        }
    }

    /// Adds the tables referenced by an access path's probe/rowid/MATCH value
    /// expressions (evaluated per outer row for a join inner).
    private static func collectAccessRefs(
        _ access: AccessPlan, into refs: inout Set<Int>, unknown: inout Bool
    ) {
        switch access {
        case .tableScan:
            break
        case .rowid(let exprs):
            for e in exprs { collectTableRefs(e, into: &refs, unknown: &unknown) }
        case .index(_, let probes, _, _):
            for probe in probes {
                for e in probe.equality { collectTableRefs(e, into: &refs, unknown: &unknown) }
                if case .range(let lower, let upper)? = probe.trailing {
                    if let lower { collectTableRefs(lower.expr, into: &refs, unknown: &unknown) }
                    if let upper { collectTableRefs(upper.expr, into: &refs, unknown: &unknown) }
                }
            }
        case .fts(_, let query, _):
            collectTableRefs(query, into: &refs, unknown: &unknown)
        }
    }

    /// Adds the COLUMN indices of `table` that `expr` reads to `columns` (F4
    /// covering analysis — the per-table refinement of `collectTableRefs`). Sets
    /// `unknown` for an unresolved/correlated `.column` or a scalar subquery, whose
    /// reachable columns can't be determined here (the caller then refuses to claim
    /// covering). Walks EVERY `SQLExpr` case — the safety of index-only serving rests
    /// on this never missing a base-table column reference, so it mirrors
    /// `collectTableRefs` exactly and adds no early-out.
    private static func collectColumnRefs(
        _ expr: SQLExpr, table: Int, into columns: inout Set<Int>, unknown: inout Bool
    ) {
        switch expr {
        case .boundColumn(let t, let c):
            if t == table { columns.insert(c) }
        case .column, .scalarSubquery:
            unknown = true
        case .literal, .parameter, .aggregateResult:
            break
        case .binary(_, let l, let r):
            collectColumnRefs(l, table: table, into: &columns, unknown: &unknown)
            collectColumnRefs(r, table: table, into: &columns, unknown: &unknown)
        case .unary(_, let i), .cast(let i, _), .collate(let i, _):
            collectColumnRefs(i, table: table, into: &columns, unknown: &unknown)
        case .isNull(let i, _):
            collectColumnRefs(i, table: table, into: &columns, unknown: &unknown)
        case .like(let s, let p, _):
            collectColumnRefs(s, table: table, into: &columns, unknown: &unknown)
            collectColumnRefs(p, table: table, into: &columns, unknown: &unknown)
        case .inList(let s, let items, _):
            collectColumnRefs(s, table: table, into: &columns, unknown: &unknown)
            for item in items { collectColumnRefs(item, table: table, into: &columns, unknown: &unknown) }
        case .inJSONEach(let s, let src, _):
            collectColumnRefs(s, table: table, into: &columns, unknown: &unknown)
            collectColumnRefs(src, table: table, into: &columns, unknown: &unknown)
        case .caseWhen(let operand, let whens, let elseExpr):
            if let operand { collectColumnRefs(operand, table: table, into: &columns, unknown: &unknown) }
            for when in whens {
                collectColumnRefs(when.condition, table: table, into: &columns, unknown: &unknown)
                collectColumnRefs(when.result, table: table, into: &columns, unknown: &unknown)
            }
            if let elseExpr { collectColumnRefs(elseExpr, table: table, into: &columns, unknown: &unknown) }
        case .function(_, let args, _, _):
            for arg in args { collectColumnRefs(arg, table: table, into: &columns, unknown: &unknown) }
        }
    }

    /// Folds an access path's probe/rowid value expressions into the per-table
    /// column set (the column-level analogue of `collectAccessRefs`). Probe values
    /// are constants/parameters in practice; included defensively so a future probe
    /// shape can never under-count the columns an index-only scan must serve.
    private static func collectColumnRefs(
        forAccess access: AccessPlan, table: Int, into columns: inout Set<Int>, unknown: inout Bool
    ) {
        switch access {
        case .tableScan:
            break
        case .rowid(let exprs):
            for e in exprs { collectColumnRefs(e, table: table, into: &columns, unknown: &unknown) }
        case .index(_, let probes, _, _):
            for probe in probes {
                for e in probe.equality { collectColumnRefs(e, table: table, into: &columns, unknown: &unknown) }
                if case .range(let lower, let upper)? = probe.trailing {
                    if let lower { collectColumnRefs(lower.expr, table: table, into: &columns, unknown: &unknown) }
                    if let upper { collectColumnRefs(upper.expr, table: table, into: &columns, unknown: &unknown) }
                }
            }
        case .fts(_, let query, _):
            collectColumnRefs(query, table: table, into: &columns, unknown: &unknown)
        }
    }

    /// Stamps an `.index` access plan as covering, attaching the index's FULL
    /// INCLUDE list (the entry-value layout the index-only decoder walks). A no-op
    /// for any non-`.index` plan.
    private static func coveringRewrite(_ access: AccessPlan, includes: [String]) -> AccessPlan {
        guard case .index(let name, let probes, let constraint, _) = access else { return access }
        return .index(name: name, probes: probes, constraint: constraint, covering: includes)
    }

    /// An exact-equality probe — every matching row satisfies the covered ON
    /// equality exactly (no trailing range to re-check). `.tableScan`/`.fts` are
    /// supersets, so never exact.
    private static func isExactEquality(_ access: AccessPlan) -> Bool {
        switch access {
        case .rowid:
            return true
        case .index(_, let probes, _, _):
            return !probes.isEmpty && probes.allSatisfy { $0.trailing == nil }
        case .tableScan, .fts:
            return false
        }
    }

    /// Overlays captured bm25() weights onto an `.fts` access plan for the table at
    /// `depth`; other plans pass through. With no bm25() call the plan keeps the
    /// Planner's default (empty → all-ones at execution), i.e. plain `rank`.
    private static func applyWeights(
        _ access: AccessPlan, _ weights: [Int: [Double]], depth: Int
    ) -> AccessPlan {
        guard case .fts(let table, let query, _) = access, let captured = weights[depth] else {
            return access
        }
        return .fts(table: table, query: query, weights: captured)
    }

    /// Resolves resolvable `.column` refs to `.boundColumn(table, column)` slots
    /// (leaving correlated outer refs as `.column`); does not descend into
    /// `.scalarSubquery` (bound independently when executed). A `bm25(tbl, …)`
    /// call is rewritten to a bound read of the table's `rank` score slot, with its
    /// weight literals captured into `weights` (keyed by the table's depth).
    static func bindColumns(
        _ expr: SQLExpr, _ binding: QueryBinding, _ weights: inout [Int: [Double]]
    ) -> SQLExpr {
        switch expr {
        case .column(let qualifier, let name, _):
            if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
                return .boundColumn(table: table, column: column)
            }
            return expr
        case .literal, .parameter, .aggregateResult, .boundColumn, .scalarSubquery:
            return expr
        case .binary(let op, let lhs, let rhs):
            return .binary(op, bindColumns(lhs, binding, &weights), bindColumns(rhs, binding, &weights))
        case .unary(let op, let inner):
            return .unary(op, bindColumns(inner, binding, &weights))
        case .like(let subject, let pattern, let negated):
            return .like(
                bindColumns(subject, binding, &weights),
                pattern: bindColumns(pattern, binding, &weights), negated: negated)
        case .isNull(let inner, let negated):
            return .isNull(bindColumns(inner, binding, &weights), negated: negated)
        case .inList(let subject, let items, let negated):
            return .inList(
                bindColumns(subject, binding, &weights),
                items.map { bindColumns($0, binding, &weights) }, negated: negated)
        case .inJSONEach(let subject, let source, let negated):
            return .inJSONEach(
                bindColumns(subject, binding, &weights),
                source: bindColumns(source, binding, &weights), negated: negated)
        case .caseWhen(let operand, let whens, let elseExpr):
            return .caseWhen(
                operand: operand.map { bindColumns($0, binding, &weights) },
                whens: whens.map {
                    SQLWhen(
                        condition: bindColumns($0.condition, binding, &weights),
                        result: bindColumns($0.result, binding, &weights))
                },
                elseExpr: elseExpr.map { bindColumns($0, binding, &weights) })
        case .function(let name, let args, let star, let offset):
            if name.uppercased() == "BM25", let bound = bindBM25(args, binding, &weights) {
                return bound
            }
            return .function(
                name: name, args: args.map { bindColumns($0, binding, &weights) }, star: star,
                offset: offset)
        case .cast(let inner, let type):
            return .cast(bindColumns(inner, binding, &weights), type)
        case .collate(let inner, let collation):
            return .collate(bindColumns(inner, binding, &weights), collation)
        }
    }

    /// Binds `bm25(tbl, w0, w1, …)`: the first argument names the FTS table (its
    /// alias-or-name, parsed as a bare column ref), the rest are numeric weight
    /// literals. Returns a bound read of the table's `rank` slot and records the
    /// authored weights under the table's depth (the executor pads/truncates them
    /// to the real column count); nil if the first argument doesn't name an FTS
    /// table in this query (so the generic `.function` path reports the error).
    private static func bindBM25(
        _ args: [SQLExpr], _ binding: QueryBinding, _ weights: inout [Int: [Double]]
    ) -> SQLExpr? {
        guard let first = args.first, case .column(let qualifier, let name, _) = first else { return nil }
        let target = qualifier ?? name
        guard let depth = binding.tables.firstIndex(where: { $0.binding == target.lowercased() }),
            binding.tables[depth].isFTS
        else { return nil }
        // Capture the authored weights as written; missing args default to 1.0 and
        // the real per-column length is resolved at execution (the synthetic binding
        // only carries [rowid, rank], not the FTS table's real text columns).
        weights[depth] = args.dropFirst().map { numericLiteral($0) ?? 1.0 }
        return .boundColumn(table: depth, column: ftsRankSlot)
    }

    /// A numeric weight literal (integer or real); nil otherwise.
    private static func numericLiteral(_ expr: SQLExpr) -> Double? {
        switch expr {
        case .literal(.integer(let value)): return Double(value)
        case .literal(.real(let value)): return value
        case .unary(.negate, let inner): return numericLiteral(inner).map { -$0 }
        default: return nil
        }
    }

}
