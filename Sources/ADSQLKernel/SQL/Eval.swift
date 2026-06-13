/// SQL expression evaluation with SQLite's exact semantics: three-valued
/// logic, cross-class comparison (INTEGER and REAL compare numerically and
/// without precision loss), collation resolution, NULL-propagating
/// operators, and arithmetic that promotes to REAL on integer overflow.
enum Truth: Equatable, Sendable {
  case yes
  case no
  case unknown

  var negated: Truth {
    switch self {
    case .yes: return .no
    case .no: return .yes
    case .unknown: return .unknown
    }
  }

  var asValue: Value {
    switch self {
    case .yes: return .integer(1)
    case .no: return .integer(0)
    case .unknown: return .null
    }
  }
}

/// SQL value comparison — distinct from `Value.keyOrder` (the index-byte
/// order), because SQL compares 1 = 1.0 numerically across storage classes.
enum SQLCompare {
  /// nil when either side is NULL (comparison result is unknown).
  static func compare(_ a: Value, _ b: Value, collation: Collation) -> Int? {
    switch (a, b) {
    case (.null, _), (_, .null):
      return nil
    case (.integer(let x), .integer(let y)):
      return x == y ? 0 : (x < y ? -1 : 1)
    case (.real(let x), .real(let y)):
      if x == y { return 0 }
      return x < y ? -1 : 1
    case (.integer(let i), .real(let d)):
      return intFloatCompare(i, d)
    case (.real(let d), .integer(let i)):
      return intFloatCompare(i, d).map { -$0 }
    case (.text(let x), .text(let y)):
      // Compare the UTF-8 views directly — no per-comparison Array allocation,
      // which dominated text-heavy ORDER BY sorts.
      return collation == .nocase ? compareUTF8NoCase(x, y) : compareUTF8(x, y)
    case (.blob(let x), .blob(let y)):
      return bytesCompare(x, y)
    default:
      // Cross-class: numeric < TEXT < BLOB (SQLite storage-class order).
      return rank(a) < rank(b) ? -1 : 1
    }
  }

  /// Exact Int64↔Double comparison (sqlite3IntFloatCompare): no precision
  /// loss at the 2^53 boundary or beyond.
  static func intFloatCompare(_ i: Int64, _ d: Double) -> Int? {
    if d.isNaN { return nil } // computed NaN behaves like NULL
    if d < -9.223372036854776e18 { return 1 }
    if d >= 9.223372036854776e18 { return -1 }
    let truncated = Int64(d)
    if i < truncated { return -1 }
    if i > truncated { return 1 }
    let fraction = d - Double(truncated)
    if fraction > 0 { return -1 }
    if fraction < 0 { return 1 }
    return 0
  }

  /// Byte-order (SQLite BINARY) comparison of two strings' UTF-8, allocation
  /// free. UTF-8 byte order equals Unicode scalar order, so this matches
  /// SQLite's memcmp on stored UTF-8.
  static func compareUTF8(_ a: String, _ b: String) -> Int {
    var lhs = a.utf8.makeIterator()
    var rhs = b.utf8.makeIterator()
    while true {
      switch (lhs.next(), rhs.next()) {
      case (nil, nil): return 0
      case (nil, _): return -1
      case (_, nil): return 1
      case (.some(let x), .some(let y)) where x != y: return x < y ? -1 : 1
      default: continue
      }
    }
  }

  /// NOCASE comparison: ASCII A–Z folded to lowercase per byte (matching
  /// SQLite's NOCASE), allocation free.
  static func compareUTF8NoCase(_ a: String, _ b: String) -> Int {
    func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c &+ 0x20 : c }
    var lhs = a.utf8.makeIterator()
    var rhs = b.utf8.makeIterator()
    while true {
      switch (lhs.next(), rhs.next()) {
      case (nil, nil): return 0
      case (nil, _): return -1
      case (_, nil): return 1
      case (.some(let x), .some(let y)):
        let fx = fold(x)
        let fy = fold(y)
        if fx != fy { return fx < fy ? -1 : 1 }
      }
    }
  }

  static func bytesCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
      if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      i += 1
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
  }

  static func rank(_ v: Value) -> Int {
    switch v {
    case .null: return 0
    case .integer, .real: return 1
    case .text: return 2
    case .blob: return 3
    }
  }

  /// SQL equality for grouping/IN under a collation.
  static func equal(_ a: Value, _ b: Value, collation: Collation) -> Truth {
    guard let c = compare(a, b, collation: collation) else { return .unknown }
    return c == 0 ? .yes : .no
  }
}

/// Evaluation environment: parameters plus row-column resolution (closures
/// provided by the executor; column refs throw outside row contexts).
struct SQLEvalEnv {
  var parameter: (SQLParam) throws(DBError) -> Value
  var column: (_ table: String?, _ name: String, _ offset: Int) throws(DBError) -> Value
  var collationOf: (_ table: String?, _ name: String) -> Collation?
  var columnTypeOf: (_ table: String?, _ name: String) -> ColumnType? = { _, _ in nil }
  /// Slot-resolved column access (the bind-time `.boundColumn` fast path): no
  /// per-row name resolution. Defaults throw so only a row context need install
  /// them.
  var boundColumn: (_ table: Int, _ column: Int) throws(DBError) -> Value = { _, _ throws(DBError) in
    throw DBError.sqlRuntime("bound column used outside a row context")
  }
  var boundCollation: (_ table: Int, _ column: Int) -> Collation? = { _, _ in nil }
  var boundColumnType: (_ table: Int, _ column: Int) -> ColumnType? = { _, _ in nil }
  /// Correlated scalar subquery executor (installed by the query executor).
  var scalarSubquery: (SQLSelect) throws(DBError) -> Value
  /// The current group's value for an aggregate slot (installed during
  /// GROUP BY finalization).
  var aggregateValue: (Int) throws(DBError) -> Value = { _ throws(DBError) in
    throw DBError.sqlRuntime("aggregate used outside an aggregate context")
  }

  static func parametersOnly(_ lookup: @escaping (SQLParam) throws(DBError) -> Value) -> SQLEvalEnv {
    SQLEvalEnv(
      parameter: lookup,
      column: { table, name, offset throws(DBError) in
        throw DBError.sqlBind(
          "column \(table.map { "\($0)." } ?? "")\(name) is not available here (offset \(offset))")
      },
      collationOf: { _, _ in nil },
      scalarSubquery: { _ throws(DBError) in
        throw DBError.sqlUnsupported("subquery in this context")
      },
    )
  }
}

enum SQLEval {
  // MARK: - Truthiness (SQLite: coerce to numeric, non-zero = true)

  static func truth(_ value: Value) -> Truth {
    switch value {
    case .null: return .unknown
    case .integer(let v): return v != 0 ? .yes : .no
    case .real(let d): return d != 0 ? .yes : .no
    case .text(let s):
      let n = SQLFunctions.numericPrefix(s)
      return truth(n)
    case .blob: return .no
    }
  }

  // MARK: - Expression evaluation

  static func evaluate(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Value {
    switch expr {
    case .literal(let value):
      return value
    case .parameter(let param, _):
      return try env.parameter(param)
    case .column(let table, let name, let offset):
      return try env.column(table, name, offset)
    case .boundColumn(let table, let column):
      return try env.boundColumn(table, column)
    case .aggregateResult(let slot):
      return try env.aggregateValue(slot)
    case .collate(let inner, _):
      return try evaluate(inner, env)
    case .cast(let inner, let type):
      return SQLFunctions.cast(try evaluate(inner, env), to: type)
    case .unary(.negate, let inner):
      return SQLFunctions.negate(try evaluate(inner, env))
    case .unary(.not, let inner):
      return predicate(of: try truthOf(inner, env).negated)
    case .isNull(let inner, let negated):
      let isNull = try evaluate(inner, env).isNull
      return .integer((isNull != negated) ? 1 : 0)
    case .binary(.and, let l, let r):
      // Short circuit per 3VL: false AND x = false.
      let lt = try truthOf(l, env)
      if lt == .no { return .integer(0) }
      let rt = try truthOf(r, env)
      if rt == .no { return .integer(0) }
      if lt == .yes && rt == .yes { return .integer(1) }
      return .null
    case .binary(.or, let l, let r):
      let lt = try truthOf(l, env)
      if lt == .yes { return .integer(1) }
      let rt = try truthOf(r, env)
      if rt == .yes { return .integer(1) }
      if lt == .no && rt == .no { return .integer(0) }
      return .null
    case .binary(let op, let l, let r) where op.isComparison:
      var lv = try evaluate(l, env)
      var rv = try evaluate(r, env)
      applyComparisonAffinity(l, &lv, r, &rv, env)
      let collation = resolveCollation(l, r, env)
      guard let c = SQLCompare.compare(lv, rv, collation: collation) else { return .null }
      let result: Bool
      switch op {
      case .eq: result = c == 0
      case .ne: result = c != 0
      case .lt: result = c < 0
      case .le: result = c <= 0
      case .gt: result = c > 0
      case .ge: result = c >= 0
      default: preconditionFailure()
      }
      return .integer(result ? 1 : 0)
    case .binary(.concat, let l, let r):
      let lv = try evaluate(l, env)
      let rv = try evaluate(r, env)
      guard !lv.isNull, !rv.isNull else { return .null }
      return .text(SQLFunctions.textify(lv) + SQLFunctions.textify(rv))
    case .binary(let op, let l, let r):
      return try SQLFunctions.arithmetic(
        op, try evaluate(l, env), try evaluate(r, env))
    case .like(let subject, let pattern, let negated):
      let s = try evaluate(subject, env)
      let p = try evaluate(pattern, env)
      guard !s.isNull, !p.isNull else { return .null }
      let matched = SQLFunctions.like(
        text: SQLFunctions.textify(s), pattern: SQLFunctions.textify(p))
      return .integer((matched != negated) ? 1 : 0)
    case .inList(let subject, let items, let negated):
      var lhs = try evaluate(subject, env)
      if items.isEmpty { return .integer(negated ? 1 : 0) }
      if lhs.isNull { return .null }
      let collation = resolveCollation(subject, nil, env)
      var sawNull = false
      for item in items {
        var rhs = try evaluate(item, env)
        applyComparisonAffinity(subject, &lhs, item, &rhs, env)
        switch SQLCompare.equal(lhs, rhs, collation: collation) {
        case .yes: return .integer(negated ? 0 : 1)
        case .unknown: sawNull = true
        case .no: break
        }
      }
      if sawNull { return .null }
      return .integer(negated ? 1 : 0)
    case .inJSONEach(let subject, let source, let negated):
      let lhs = try evaluate(subject, env)
      let json = try evaluate(source, env)
      if json.isNull { return .integer(negated ? 1 : 0) } // empty rowset
      guard case .text(let text) = json else {
        throw DBError.sqlRuntime("json_each requires TEXT input")
      }
      let values = try SQLJSON.eachValues(text)
      if values.isEmpty { return .integer(negated ? 1 : 0) }
      if lhs.isNull { return .null }
      let collation = resolveCollation(subject, nil, env)
      var sawNull = false
      for rhs in values {
        switch SQLCompare.equal(lhs, rhs, collation: collation) {
        case .yes: return .integer(negated ? 0 : 1)
        case .unknown: sawNull = true
        case .no: break
        }
      }
      if sawNull { return .null }
      return .integer(negated ? 1 : 0)
    case .scalarSubquery(let select):
      return try env.scalarSubquery(select)
    case .caseWhen(let operand, let whens, let elseExpr):
      if let operand {
        let base = try evaluate(operand, env)
        let collation = resolveCollation(operand, nil, env)
        for when in whens {
          let candidate = try evaluate(when.condition, env)
          if SQLCompare.equal(base, candidate, collation: collation) == .yes {
            return try evaluate(when.result, env)
          }
        }
      } else {
        for when in whens {
          if try truthOf(when.condition, env) == .yes {
            return try evaluate(when.result, env)
          }
        }
      }
      if let elseExpr { return try evaluate(elseExpr, env) }
      return .null
    case .function(let name, let args, let star, let offset):
      return try SQLFunctions.call(name, args: args, star: star, offset: offset, env)
    }
  }

  static func truthOf(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Truth {
    truth(try evaluate(expr, env))
  }

  static func predicate(of truth: Truth) -> Value {
    truth.asValue
  }

  // MARK: - Comparison affinity (SQLite §type affinity in comparisons)

  enum Affinity { case numeric, text, none }

  static func affinity(_ expr: SQLExpr, _ env: SQLEvalEnv) -> Affinity {
    switch expr {
    case .cast(_, .integer), .cast(_, .real):
      return .numeric
    case .cast(_, .text):
      return .text
    case .cast(_, .blob):
      return .none
    case .column(let table, let name, _):
      switch env.columnTypeOf(table, name) {
      case .integer, .real: return .numeric
      case .text: return .text
      case .blob, nil: return .none
      }
    case .boundColumn(let table, let column):
      switch env.boundColumnType(table, column) {
      case .integer, .real: return .numeric
      case .text: return .text
      case .blob, nil: return .none
      }
    case .binary(.concat, _, _):
      return .text
    case .binary(let op, _, _) where !op.isComparison && op != .and && op != .or:
      return .numeric
    case .unary(.negate, _):
      return .numeric
    case .collate(let inner, _):
      return affinity(inner, env)
    default:
      return .none
    }
  }

  /// One side with numeric affinity converts the other side's well-formed
  /// numeric TEXT; one side with TEXT affinity textifies the other side's
  /// bare numerics.
  static func applyComparisonAffinity(
    _ l: SQLExpr, _ lv: inout Value, _ r: SQLExpr, _ rv: inout Value, _ env: SQLEvalEnv
  ) {
    let la = affinity(l, env)
    let ra = affinity(r, env)
    if la == .numeric || ra == .numeric {
      if case .text(let s) = lv, let n = SQLFunctions.fullNumeric(s) { lv = n }
      if case .text(let s) = rv, let n = SQLFunctions.fullNumeric(s) { rv = n }
      return
    }
    if la == .text && ra == .none {
      if case .integer = rv { rv = .text(SQLFunctions.textify(rv)) }
      if case .real = rv { rv = .text(SQLFunctions.textify(rv)) }
    } else if ra == .text && la == .none {
      if case .integer = lv { lv = .text(SQLFunctions.textify(lv)) }
      if case .real = lv { lv = .text(SQLFunctions.textify(lv)) }
    }
  }

  /// Collation resolution: explicit COLLATE wins, else the left column's
  /// collation, else the right column's, else BINARY.
  static func resolveCollation(_ l: SQLExpr, _ r: SQLExpr?, _ env: SQLEvalEnv) -> Collation {
    if let explicit = explicitCollation(l) { return explicit }
    if let r, let explicit = explicitCollation(r) { return explicit }
    if let implied = impliedCollation(l, env) { return implied }
    if let r, let implied = impliedCollation(r, env) { return implied }
    return .binary
  }

  private static func explicitCollation(_ expr: SQLExpr) -> Collation? {
    switch expr {
    case .collate(_, let collation): return collation
    case .unary(_, let inner), .cast(let inner, _): return explicitCollation(inner)
    default: return nil
    }
  }

  private static func impliedCollation(_ expr: SQLExpr, _ env: SQLEvalEnv) -> Collation? {
    switch expr {
    case .column(let table, let name, _): return env.collationOf(table, name)
    case .boundColumn(let table, let column): return env.boundCollation(table, column)
    case .collate(let inner, _), .unary(_, let inner), .cast(let inner, _):
      return impliedCollation(inner, env)
    default: return nil
    }
  }
}

extension SQLBinaryOp {
  var isComparison: Bool {
    switch self {
    case .eq, .ne, .lt, .le, .gt, .ge: return true
    default: return false
    }
  }
}
