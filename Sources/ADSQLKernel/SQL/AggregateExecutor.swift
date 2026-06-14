/// Aggregate + GROUP BY execution for `SelectExecutor` (RFC 0009 H2/R4 — split
/// from Executor.swift). `runAggregated` drives the grouped/ungrouped aggregate
/// pipeline (COUNT/SUM/… accumulation, HAVING, finalization) and `aggregateEnv`
/// installs the per-group evaluation environment. `SelectExecutor` statics in an
/// extension; pure code motion + visibility.
extension SelectExecutor {
    static func runAggregated<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
        joinIndexes: [Catalog.IndexRecord?], ftsRecords: [String: Catalog.FTSRecord],
        resolver: R, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
        execution: ExecutionOptions = .default,
        mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil
    ) throws(DBError) -> [SQLRow] {
        let context = RowContext(definitions: tables.map(\.definition))
        context.mergeIndexes = mergeIndexes
        let scanEnv = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
        let paramsEnv = SQLEvalEnv.parametersOnly { p throws(DBError) in try params.lookup(p) }
        let columnCounts = plan.binding.tables.map(\.columnNames.count)
        let noGroupBy = plan.groupBy.isEmpty

        var order: [GroupKey] = []
        var groups: [GroupKey: (accumulators: GroupAccumulators, representative: [[Value]])] = [:]

        // An aggregate with no GROUP BY always produces exactly one row (COUNT 0,
        // SUM NULL over an empty input), so seed the single implicit group.
        let implicitKey = GroupKey([], collations: [])
        if noGroupBy {
            let empty = columnCounts.map { Array(repeating: Value.null, count: $0) }
            groups[implicitKey] = (GroupAccumulators(specs: plan.aggregates), empty)
            order.append(implicitKey)
        }

        try forEachFilteredRow(
            plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
            resolver: resolver, context: context, env: scanEnv, paramsEnv: paramsEnv, execution: execution
        ) { () throws(DBError) in
            let key: GroupKey
            if noGroupBy {
                key = implicitKey
            } else {
                var parts: [Value] = []
                for expr in plan.groupBy { parts.append(try SQLEval.evaluate(expr, scanEnv)) }
                key = GroupKey(parts, collations: plan.groupCollations)
            }
            if groups[key] == nil {
                var representative: [[Value]] = []
                for table in tables.indices {
                    // Skip materializing a table whose representative no output/HAVING/
                    // ORDER BY reads (e.g. COUNT(*)). Required for an existence-only inner,
                    // whose slot holds an empty span — decoding it would be wrong.
                    let needed = plan.finalizationReferencedTables.contains(table)
                    representative.append(
                        (needed && !context.nullExtended[table])
                            ? try context.slots[table].materialize()
                            : Array(repeating: Value.null, count: columnCounts[table]))
                }
                groups[key] = (GroupAccumulators(specs: plan.aggregates), representative)
                order.append(key)
            }
            try groups[key]!.accumulators.update(scanEnv)
        }

        var rows: [[Value]] = []
        var sortKeys: [[Value]] = []
        let collectKeys = !plan.orderBy.isEmpty
        for key in order {
            let group = groups[key]!
            let env = aggregateEnv(
                plan.binding, representative: group.representative,
                accumulators: group.accumulators, params: params)
            if let having = plan.having {
                if SQLEval.truth(try SQLEval.evaluate(having, env)) != .yes { continue }
            }
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
            let permutation = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
            rows = permutation.map { rows[$0] }
        }
        if let bounds = try sliceBounds(plan, params: params) {
            let lower = min(bounds.offset, rows.count)
            let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
            rows = Array(rows[lower..<upper])
        }
        return rows.map { SQLRow(header: plan.header, values: $0) }
    }

    /// Finalization env for one group: column references read the group's
    /// representative row; `aggregateResult` slots read the accumulators.
    private static func aggregateEnv(
        _ binding: QueryBinding, representative: [[Value]], accumulators: GroupAccumulators,
        params: SQLParameters
    ) -> SQLEvalEnv {
        SQLEvalEnv(
            parameter: { parameter throws(DBError) in try params.lookup(parameter) },
            column: { (qualifier, name, _) throws(DBError) in
                guard let (table, column) = binding.resolve(qualifier: qualifier, name: name) else {
                    throw DBError.noSuchColumn(table: qualifier ?? binding.tables[0].table, column: name)
                }
                return representative[table][column]
            },
            collationOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnCollations[$0.column] }
            },
            columnTypeOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnTypes[$0.column] }
            },
            boundColumn: { (table, column) throws(DBError) in representative[table][column] },
            boundCollation: { (table, column) in binding.tables[table].columnCollations[column] },
            boundColumnType: { (table, column) in binding.tables[table].columnTypes[column] },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery (arrives in a later slice)")
            },
            aggregateValue: { slot throws(DBError) in accumulators.result(slot) })
    }
}
