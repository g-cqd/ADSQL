/// Bind-time expression compilation: lowers a bound `SQLExpr` to a closure tree
/// ONCE, so a per-row evaluation skips the recursive `indirect enum` switch and
/// bakes in the schema-fixed work that `SQLEval.evaluate` recomputes every row —
/// slot reads (straight to `RowContext.value`, no env closure), comparison
/// affinity, and collation resolution.
///
/// Semantics are identical to `SQLEval.evaluate` by construction (same 3VL, NULL
/// propagation, `SQLCompare`, `SQLFunctions`, affinity/collation rules); only the
/// *timing* of resolution changes. `compile` returns nil for any case it does not
/// yet handle, so the caller falls back to the tree-walk evaluator — making the
/// compiled path safe-by-construction and incrementally expandable. The compiled
/// vs tree-walk equivalence is locked by the strategy-matrix differential tests.
enum CompiledEval {
  typealias Thunk = () throws(DBError) -> Value

  /// Compiles `expr` against the live `context`/`params`; `env` supplies the
  /// schema-fixed affinity/collation resolution at compile time only. Returns nil
  /// when a sub-expression is unsupported (correlated `.column`, subqueries,
  /// aggregates, IN/LIKE/json/function, MATCH) → caller uses tree-walk.
  static func compile(
    _ expr: SQLExpr, context: SelectExecutor.RowContext, params: SQLParameters, env: SQLEvalEnv
  ) -> Thunk? {
    func sub(_ e: SQLExpr) -> Thunk? { compile(e, context: context, params: params, env: env) }

    switch expr {
    case .literal(let value):
      return { () throws(DBError) -> Value in value }
    case .boundColumn(let table, let column):
      return { () throws(DBError) -> Value in try context.value(table: table, column: column) }
    case .parameter(let parameter, _):
      return { () throws(DBError) -> Value in try params.lookup(parameter) }
    case .collate(let inner, _):
      // COLLATE changes a comparison's collation (baked below), not the value.
      return sub(inner)
    case .cast(let inner, let type):
      guard let inner = sub(inner) else { return nil }
      return { () throws(DBError) -> Value in SQLFunctions.cast(try inner(), to: type) }
    case .unary(.negate, let inner):
      guard let inner = sub(inner) else { return nil }
      return { () throws(DBError) -> Value in SQLFunctions.negate(try inner()) }
    case .unary(.not, let inner):
      guard let inner = sub(inner) else { return nil }
      return { () throws(DBError) -> Value in SQLEval.predicate(of: SQLEval.truth(try inner()).negated) }
    case .isNull(let inner, let negated):
      guard let inner = sub(inner) else { return nil }
      return { () throws(DBError) -> Value in .integer((try inner().isNull != negated) ? 1 : 0) }
    case .binary(.and, let l, let r):
      guard let cl = sub(l), let cr = sub(r) else { return nil }
      return { () throws(DBError) -> Value in
        let lt = SQLEval.truth(try cl())
        if lt == .no { return .integer(0) }
        let rt = SQLEval.truth(try cr())
        if rt == .no { return .integer(0) }
        return (lt == .yes && rt == .yes) ? .integer(1) : .null
      }
    case .binary(.or, let l, let r):
      guard let cl = sub(l), let cr = sub(r) else { return nil }
      return { () throws(DBError) -> Value in
        let lt = SQLEval.truth(try cl())
        if lt == .yes { return .integer(1) }
        let rt = SQLEval.truth(try cr())
        if rt == .yes { return .integer(1) }
        return (lt == .no && rt == .no) ? .integer(0) : .null
      }
    case .binary(let op, let l, let r) where op.isComparison:
      guard let cl = sub(l), let cr = sub(r) else { return nil }
      // Bake affinities + collation now (schema-fixed); apply only the runtime
      // value coercion per row, exactly as `SQLEval` does.
      let la = SQLEval.affinity(l, env)
      let ra = SQLEval.affinity(r, env)
      let collation = SQLEval.resolveCollation(l, r, env)
      return { () throws(DBError) -> Value in
        var lv = try cl()
        var rv = try cr()
        SQLEval.applyAffinities(la, ra, &lv, &rv)
        guard let c = SQLCompare.compare(lv, rv, collation: collation) else { return .null }
        guard let result = op.comparisonResult(c) else { return .null }
        return .integer(result ? 1 : 0)
      }
    case .binary(.concat, let l, let r):
      guard let cl = sub(l), let cr = sub(r) else { return nil }
      return { () throws(DBError) -> Value in
        let lv = try cl()
        let rv = try cr()
        guard !lv.isNull, !rv.isNull else { return .null }
        return .text(SQLFunctions.textify(lv) + SQLFunctions.textify(rv))
      }
    case .binary(.match, _, _):
      return nil  // an access path, never row-evaluated
    case .binary(let op, let l, let r):  // arithmetic (NULL-propagating, REAL promote)
      guard let cl = sub(l), let cr = sub(r) else { return nil }
      return { () throws(DBError) -> Value in try SQLFunctions.arithmetic(op, try cl(), try cr()) }
    case .caseWhen(let operand, let whens, let elseExpr):
      var arms: [(Thunk, Thunk)] = []
      arms.reserveCapacity(whens.count)
      for when in whens {
        guard let cond = sub(when.condition), let result = sub(when.result) else { return nil }
        arms.append((cond, result))
      }
      let elseThunk: Thunk?
      if let elseExpr {
        guard let e = sub(elseExpr) else { return nil }
        elseThunk = e
      } else {
        elseThunk = nil
      }
      if let operand {
        guard let base = sub(operand) else { return nil }
        let collation = SQLEval.resolveCollation(operand, nil, env)
        return { () throws(DBError) -> Value in
          let baseValue = try base()
          for (cond, result) in arms
          where SQLCompare.equal(baseValue, try cond(), collation: collation) == .yes {
            return try result()
          }
          return try elseThunk?() ?? .null
        }
      }
      return { () throws(DBError) -> Value in
        for (cond, result) in arms where SQLEval.truth(try cond()) == .yes {
          return try result()
        }
        return try elseThunk?() ?? .null
      }
    case .like(let subject, let pattern, let negated):
      guard let cs = sub(subject), let cp = sub(pattern) else { return nil }
      return { () throws(DBError) -> Value in
        let s = try cs()
        let p = try cp()
        guard !s.isNull, !p.isNull else { return .null }
        let matched = SQLFunctions.like(
          text: SQLFunctions.textify(s), pattern: SQLFunctions.textify(p))
        return .integer((matched != negated) ? 1 : 0)
      }
    case .inList(let subject, let items, let negated):
      guard let cs = sub(subject) else { return nil }
      // Empty list is a constant, but tree-walk still evaluates `subject` first —
      // mirror that (its evaluation may throw) before returning the constant.
      if items.isEmpty {
        return { () throws(DBError) -> Value in _ = try cs(); return .integer(negated ? 1 : 0) }
      }
      // Bake each side's (schema-fixed) affinity + the collation now; the per-row
      // thunk applies only the value coercion, exactly as `SQLEval.inList` does —
      // including the `lhs` carry across items (a numeric-affinity item coerces a
      // TEXT lhs once, and the coerced value persists for the remaining items).
      var compiledItems: [(Thunk, SQLEval.Affinity)] = []
      compiledItems.reserveCapacity(items.count)
      for item in items {
        guard let ci = sub(item) else { return nil }
        compiledItems.append((ci, SQLEval.affinity(item, env)))
      }
      let subjectAffinity = SQLEval.affinity(subject, env)
      let collation = SQLEval.resolveCollation(subject, nil, env)
      return { () throws(DBError) -> Value in
        var lhs = try cs()
        if lhs.isNull { return .null }
        var sawNull = false
        for (item, itemAffinity) in compiledItems {
          var rhs = try item()
          SQLEval.applyAffinities(subjectAffinity, itemAffinity, &lhs, &rhs)
          switch SQLCompare.equal(lhs, rhs, collation: collation) {
          case .yes: return .integer(negated ? 0 : 1)
          case .unknown: sawNull = true
          case .no: break
          }
        }
        if sawNull { return .null }
        return .integer(negated ? 1 : 0)
      }
    case .function(let name, let args, let star, let offset):
      // `SQLFunctions.call` evaluates its argument expressions through `env` (which
      // is wired to the same row context), so compiling the call site does not
      // compile the arguments — but it lets a scalar function participate in an
      // otherwise-compiled expression (e.g. `upper(x) = ?`) instead of forcing the
      // whole expression onto the tree-walk fallback. Identical semantics.
      return { () throws(DBError) -> Value in
        try SQLFunctions.call(name, args: args, star: star, offset: offset, env)
      }
    default:
      // .column (correlated), .scalarSubquery, .inJSONEach, .aggregateResult —
      // handled by the tree-walk fallback.
      return nil
    }
  }
}
