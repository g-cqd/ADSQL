/// Heuristic access-path selection for single-table SELECT. The planner
/// extracts sargable conjuncts from a WHERE clause and picks a row source that
/// is a *superset* of the rows the predicate accepts; the executor re-applies
/// the full original WHERE as a residual, so the planner can never change
/// results — only how many rows are touched. It also reports whether the
/// chosen source already yields ORDER BY order (so the executor can skip the
/// sort and early-exit under LIMIT).
///
/// PR4 paths: full scan, rowid point/IN, and index equality-prefix with an
/// optional trailing range column (and IN on a leading index column). Type
/// boundaries are bridged conservatively: an equality probe whose value does
/// not convert exactly to the column's class is provably empty (distinct
/// classes never compare equal under strict typing) or falls back to a scan;
/// range bounds apply only when the bound value matches the column's class.

/// A lower/upper bound expression plus whether it includes the endpoint.
struct BoundExpr: Sendable {
  let expr: SQLExpr
  let inclusive: Bool
}

enum Trailing: Sendable {
  case range(lower: BoundExpr?, upper: BoundExpr?)
}

/// One index range: equality values for the leading columns plus an optional
/// range on the next column.
struct IndexProbe: Sendable {
  let equality: [SQLExpr]
  let trailing: Trailing?
}

enum AccessPlan: Sendable {
  case tableScan
  case rowid([SQLExpr])               // one (eq) or many (IN) rowid probes
  case index(name: String, probes: [IndexProbe], constraint: String)
}

/// The result of planning: the access path plus order analysis.
struct AccessPlanning: Sendable {
  let plan: AccessPlan
  /// The chosen path's natural order satisfies ORDER BY (single contiguous
  /// range or ≤1 row, all ASC, matching collations).
  let yieldsOrder: Bool
  /// Rowid (table) order satisfies ORDER BY — used when an index probe falls
  /// back to a table scan at execution time.
  let rowidOrderSatisfiesOrderBy: Bool
  /// The original WHERE conjuncts this probe satisfies *exactly* (the
  /// equality-prefix `col = const` / rowid eq / rowid IN). The executor may
  /// drop them from the residual when it uses the probe (not the scan
  /// fallback). The trailing range column is never exact, so it is excluded.
  var coveredConjuncts: [SQLExpr] = []
}

enum Planner {
  // MARK: - Sargable constraints

  private enum Constraint {
    case eq(column: Int, value: SQLExpr, source: SQLExpr)
    case inList(column: Int, values: [SQLExpr], source: SQLExpr)
    case lower(column: Int, value: SQLExpr, inclusive: Bool)
    case upper(column: Int, value: SQLExpr, inclusive: Bool)
  }

  static func plan(
    where whereExpr: SQLExpr?, orderBy: [SQLOrderingTerm],
    source: TableBinding, indexes: [IndexDefinition], definition: TableDefinition
  ) -> AccessPlanning {
    let constraints = whereExpr.map { extract(conjuncts($0), source: source) } ?? []
    let rowidOrder = rowidOrderSatisfies(orderBy, source: source)

    // 1. Rowid point / IN (the rowid-alias column).
    if let aliasIndex = source.rowidAliasIndex {
      if let eq = firstEquality(constraints, column: aliasIndex) {
        return AccessPlanning(
          plan: .rowid([eq.value]), yieldsOrder: true,
          rowidOrderSatisfiesOrderBy: rowidOrder, coveredConjuncts: [eq.source])
      }
      if let inList = firstInList(constraints, column: aliasIndex) {
        let ordered = inList.values.count <= 1 || orderBy.isEmpty
        return AccessPlanning(
          plan: .rowid(inList.values), yieldsOrder: ordered,
          rowidOrderSatisfiesOrderBy: rowidOrder, coveredConjuncts: [inList.source])
      }
    }

    // 2. Best index by equality-prefix length, then trailing range, then IN
    //    on a sole leading column.
    if let chosen = chooseIndex(
      constraints, orderBy: orderBy, source: source, indexes: indexes,
      definition: definition, rowidOrder: rowidOrder)
    {
      return chosen
    }

    // 3. Full scan.
    return AccessPlanning(
      plan: .tableScan,
      yieldsOrder: orderBy.isEmpty || rowidOrder,
      rowidOrderSatisfiesOrderBy: rowidOrder)
  }

  /// Index/rowid access for a join's inner table from `inner.col = <outer expr>`
  /// equalities (the values are evaluated per outer row at execution). Mirrors
  /// the leading-table equality-prefix logic; order is irrelevant for a probe.
  /// Returns `.tableScan` when no equality hits the rowid alias or an index.
  static func planJoin(
    equalities: [(column: Int, value: SQLExpr)],
    inner: TableBinding, indexes: [IndexDefinition], definition: TableDefinition
  ) -> AccessPlan {
    guard !equalities.isEmpty else { return .tableScan }
    let constraints = equalities.map { Constraint.eq(column: $0.column, value: $0.value, source: $0.value) }
    if let aliasIndex = inner.rowidAliasIndex, let eq = firstEquality(constraints, column: aliasIndex) {
      return .rowid([eq.value])
    }
    if let chosen = chooseIndex(
      constraints, orderBy: [], source: inner, indexes: indexes,
      definition: definition, rowidOrder: false)
    {
      return chosen.plan
    }
    return .tableScan
  }

  // MARK: - Index selection

  private static func chooseIndex(
    _ constraints: [Constraint], orderBy: [SQLOrderingTerm],
    source: TableBinding, indexes: [IndexDefinition], definition: TableDefinition,
    rowidOrder: Bool
  ) -> AccessPlanning? {
    var best: (planning: AccessPlanning, score: Int)?

    for index in indexes.sorted(by: { $0.name < $1.name }) {
      let columns = index.columns.compactMap { definition.columnIndex(of: $0) }
      guard columns.count == index.columns.count else { continue }

      // Longest leading equality prefix.
      var equality: [SQLExpr] = []
      var covered: [SQLExpr] = []
      var prefixLen = 0
      while prefixLen < columns.count, let eq = firstEquality(constraints, column: columns[prefixLen]) {
        equality.append(eq.value)
        covered.append(eq.source)
        prefixLen += 1
      }

      // Optional trailing range on the column right after the prefix.
      var trailing: Trailing?
      var constraintText = equality.indices.map { "\(index.columns[$0])=?" }
      if prefixLen < columns.count {
        let rangeColumn = columns[prefixLen]
        let lower = firstLower(constraints, column: rangeColumn)
        let upper = firstUpper(constraints, column: rangeColumn)
        if lower != nil || upper != nil {
          trailing = .range(lower: lower, upper: upper)
          constraintText.append("\(index.columns[prefixLen]) range")
        }
      }

      // IN on a sole leading column (no equality prefix consumed yet).
      if prefixLen == 0, trailing == nil, columns.count >= 1,
        let inList = firstInList(constraints, column: columns[0])
      {
        let yields = inList.values.count <= 1 || orderBy.isEmpty
        let planning = AccessPlanning(
          plan: .index(
            name: index.name,
            probes: inList.values.map { IndexProbe(equality: [$0], trailing: nil) },
            constraint: "\(index.columns[0]) IN (\(inList.values.count))"),
          yieldsOrder: yields,
          rowidOrderSatisfiesOrderBy: rowidOrder,
          coveredConjuncts: [inList.source])
        consider(&best, planning, score: 1)
        continue
      }

      let hasTrailing = trailing != nil
      guard prefixLen > 0 || hasTrailing else { continue }

      let yields = indexYieldsOrder(
        orderBy, columns: columns, prefixConsumed: prefixLen + (hasTrailing ? 1 : 0),
        source: source, index: index, definition: definition)
      let planning = AccessPlanning(
        plan: .index(
          name: index.name,
          probes: [IndexProbe(equality: equality, trailing: trailing)],
          constraint: constraintText.joined(separator: " AND ")),
        yieldsOrder: orderBy.isEmpty || yields,
        rowidOrderSatisfiesOrderBy: rowidOrder,
        coveredConjuncts: covered)
      // Score: equality columns dominate; a trailing range and uniqueness
      // break ties.
      let score = prefixLen * 4 + (hasTrailing ? 2 : 0) + (index.unique ? 1 : 0)
      consider(&best, planning, score: score)
    }

    return best?.planning
  }

  private static func consider(
    _ best: inout (planning: AccessPlanning, score: Int)?, _ planning: AccessPlanning, score: Int
  ) {
    if best == nil || score > best!.score {
      best = (planning, score)
    }
  }

  // MARK: - Order analysis

  /// ORDER BY satisfied by index order: terms (after the consumed prefix
  /// columns) match the index columns in order, all ascending, with matching
  /// collations.
  private static func indexYieldsOrder(
    _ orderBy: [SQLOrderingTerm], columns: [Int], prefixConsumed: Int,
    source: TableBinding, index: IndexDefinition, definition: TableDefinition
  ) -> Bool {
    guard !orderBy.isEmpty else { return true }
    guard let terms = orderColumns(orderBy, source: source) else { return false }
    guard prefixConsumed + terms.count <= columns.count else { return false }
    for (offset, term) in terms.enumerated() {
      let indexPosition = prefixConsumed + offset
      guard term.column == columns[indexPosition], !term.descending else { return false }
      let columnCollation = definition.columns[columns[indexPosition]].collation
      guard term.collation == columnCollation else { return false }
    }
    return true
  }

  private static func rowidOrderSatisfies(_ orderBy: [SQLOrderingTerm], source: TableBinding) -> Bool {
    guard let aliasIndex = source.rowidAliasIndex else { return false }
    guard let terms = orderColumns(orderBy, source: source), terms.count == 1 else { return false }
    return terms[0].column == aliasIndex && !terms[0].descending
  }

  private struct OrderColumn { let column: Int; let descending: Bool; let collation: Collation }

  /// Order terms reduced to (column, direction, collation), or nil if any term
  /// is not a plain column reference.
  private static func orderColumns(
    _ orderBy: [SQLOrderingTerm], source: TableBinding
  ) -> [OrderColumn]? {
    var result: [OrderColumn] = []
    for term in orderBy {
      var expr = term.expr
      var collation: Collation?
      if case .collate(let inner, let explicit) = expr {
        expr = inner
        collation = explicit
      }
      guard case .column(let qualifier, let name, _) = expr,
        let column = source.columnIndex(qualifier: qualifier, name: name)
      else { return nil }
      result.append(
        OrderColumn(
          column: column, descending: term.descending,
          collation: collation ?? source.columnCollations[column]))
    }
    return result
  }

  // MARK: - Conjunct classification

  private static func conjuncts(_ expr: SQLExpr) -> [SQLExpr] {
    if case .binary(.and, let lhs, let rhs) = expr {
      return conjuncts(lhs) + conjuncts(rhs)
    }
    return [expr]
  }

  private static func extract(_ conjuncts: [SQLExpr], source: TableBinding) -> [Constraint] {
    var constraints: [Constraint] = []
    for conjunct in conjuncts {
      switch conjunct {
      case .binary(let op, let lhs, let rhs) where op.isComparison:
        if let column = columnReference(lhs, source: source), isConstant(rhs) {
          appendComparison(op, column: column, value: rhs, flipped: false, source: conjunct, to: &constraints)
        } else if let column = columnReference(rhs, source: source), isConstant(lhs) {
          appendComparison(op, column: column, value: lhs, flipped: true, source: conjunct, to: &constraints)
        }
      case .inList(let subject, let items, let negated):
        if !negated, let column = columnReference(subject, source: source),
          !items.isEmpty, items.allSatisfy(isConstant)
        {
          constraints.append(.inList(column: column, values: items, source: conjunct))
        }
      default:
        break
      }
    }
    return constraints
  }

  private static func appendComparison(
    _ op: SQLBinaryOp, column: Int, value: SQLExpr, flipped: Bool, source: SQLExpr,
    to constraints: inout [Constraint]
  ) {
    // When the column is on the right, the comparison direction flips.
    let effective: SQLBinaryOp
    switch (op, flipped) {
    case (.lt, true): effective = .gt
    case (.gt, true): effective = .lt
    case (.le, true): effective = .ge
    case (.ge, true): effective = .le
    default: effective = op
    }
    switch effective {
    case .eq: constraints.append(.eq(column: column, value: value, source: source))
    case .lt: constraints.append(.upper(column: column, value: value, inclusive: false))
    case .le: constraints.append(.upper(column: column, value: value, inclusive: true))
    case .gt: constraints.append(.lower(column: column, value: value, inclusive: false))
    case .ge: constraints.append(.lower(column: column, value: value, inclusive: true))
    default: break  // != is not sargable
    }
  }

  private static func columnReference(_ expr: SQLExpr, source: TableBinding) -> Int? {
    guard case .column(let qualifier, let name, _) = expr else { return nil }
    return source.columnIndex(qualifier: qualifier, name: name)
  }

  /// An expression with no column references (and no subqueries): evaluable
  /// from parameters alone at execution time.
  private static func isConstant(_ expr: SQLExpr) -> Bool {
    switch expr {
    case .column, .scalarSubquery, .inJSONEach, .aggregateResult:
      return false
    case .literal, .parameter:
      return true
    case .collate(let inner, _), .cast(let inner, _), .unary(_, let inner):
      return isConstant(inner)
    case .isNull(let inner, _):
      return isConstant(inner)
    case .binary(_, let lhs, let rhs):
      return isConstant(lhs) && isConstant(rhs)
    case .like(let subject, let pattern, _):
      return isConstant(subject) && isConstant(pattern)
    case .inList(let subject, let items, _):
      return isConstant(subject) && items.allSatisfy(isConstant)
    case .caseWhen(let operand, let whens, let elseExpr):
      return (operand.map(isConstant) ?? true)
        && whens.allSatisfy { isConstant($0.condition) && isConstant($0.result) }
        && (elseExpr.map(isConstant) ?? true)
    case .function(_, let args, _, _):
      return args.allSatisfy(isConstant)
    }
  }

  private static func firstEquality(
    _ constraints: [Constraint], column: Int
  ) -> (value: SQLExpr, source: SQLExpr)? {
    for case .eq(let c, let value, let source) in constraints where c == column {
      return (value, source)
    }
    return nil
  }
  private static func firstInList(
    _ constraints: [Constraint], column: Int
  ) -> (values: [SQLExpr], source: SQLExpr)? {
    for case .inList(let c, let values, let source) in constraints where c == column {
      return (values, source)
    }
    return nil
  }
  private static func firstLower(_ constraints: [Constraint], column: Int) -> BoundExpr? {
    for case .lower(let c, let value, let inclusive) in constraints where c == column {
      return BoundExpr(expr: value, inclusive: inclusive)
    }
    return nil
  }
  private static func firstUpper(_ constraints: [Constraint], column: Int) -> BoundExpr? {
    for case .upper(let c, let value, let inclusive) in constraints where c == column {
      return BoundExpr(expr: value, inclusive: inclusive)
    }
    return nil
  }
}

extension AccessPlan {
  /// SQLite-EXPLAIN-shaped description for planner assertions.
  func describe(table: String) -> String {
    switch self {
    case .tableScan:
      return "SCAN \(table)"
    case .rowid(let probes):
      return probes.count > 1 ? "SEARCH \(table) USING ROWID (IN)" : "SEARCH \(table) USING ROWID"
    case .index(let name, _, let constraint):
      return "SEARCH \(table) USING INDEX \(name) (\(constraint))"
    }
  }

  var indexName: String? {
    if case .index(let name, _, _) = self { return name }
    return nil
  }
}
