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
        if d.isNaN { return nil }  // computed NaN behaves like NULL
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

    /// `compareUTF8` over raw byte buffers (the zero-copy top-N path) — identical
    /// result to the `String` version on the same UTF-8 bytes: byte-lexicographic,
    /// shorter sorts first when a prefix.
    static func compareUTF8(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let x = unsafe a[i]
            let y = unsafe b[i]
            if x != y { return x < y ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    /// `compareUTF8NoCase` over raw byte buffers (ASCII A–Z folded per byte).
    static func compareUTF8NoCase(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c &+ 0x20 : c }
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let fx = unsafe fold(a[i])
            let fy = unsafe fold(b[i])
            if fx != fy { return fx < fy ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
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
            guard let result = op.comparisonResult(c) else { return .null }
            return .integer(result ? 1 : 0)
        case .binary(.concat, let l, let r):
            let lv = try evaluate(l, env)
            let rv = try evaluate(r, env)
            guard !lv.isNull, !rv.isNull else { return .null }
            return .text(SQLFunctions.textify(lv) + SQLFunctions.textify(rv))
        case .binary(.match, _, _):
            // MATCH is an access path (the planner lowers it to `.fts`), never a
            // row-level predicate; reaching here means it appeared where it can't
            // drive an FTS scan (e.g. a projection, or on a non-FTS table).
            throw DBError.sqlRuntime("MATCH is only valid as a WHERE constraint on an FTS table")
        case .binary(.jsonExtract, let l, let r):
            return try SQLJSON.arrow(try evaluate(l, env), try evaluate(r, env), asJSON: true)
        case .binary(.jsonExtractText, let l, let r):
            return try SQLJSON.arrow(try evaluate(l, env), try evaluate(r, env), asJSON: false)
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
            if json.isNull { return .integer(negated ? 1 : 0) }  // empty rowset
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

    // MARK: - Query-invariant subexpression folding

    /// Functions that are NOT a pure function of their arguments (their value can
    /// differ between two evaluations with identical inputs), so a subtree
    /// containing one must never be hoisted to a per-execution constant. ADSQL's
    /// only such function is `datetime('now')` (wall clock). Uppercased to match
    /// the case-insensitive dispatch in `SQLFunctions.call`.
    static let nonDeterministicFunctions: Set<String> = ["DATETIME"]

    /// True when `expr`'s ENTIRE subtree is *query-invariant*: it references no row
    /// value (`.column`/`.boundColumn`), no aggregate (`.aggregateResult`), and no
    /// subquery (`.scalarSubquery`), and contains no non-deterministic function or
    /// `MATCH` operator — so it evaluates to the SAME value for every row of a
    /// single execution once the parameters are bound. Such a subtree is exactly
    /// `.literal`/`.parameter` combined through pure operators/functions.
    ///
    /// This is the correctness crux of `foldInvariant`: it is the single predicate
    /// that decides whether a subtree may be pre-evaluated. It conservatively
    /// refuses (returns false) for anything row- or query-shape-dependent, and for
    /// `MATCH` (an access path that throws if row-evaluated). Mirrors the binder's
    /// `collectTableRefs`/`referencesOnlyBelow` walks so it cannot miss a case.
    static func isInvariant(_ expr: SQLExpr) -> Bool {
        switch expr {
        case .literal, .parameter:
            return true
        case .column, .boundColumn, .aggregateResult, .scalarSubquery:
            // Row value / aggregate group value / per-row subquery result: never
            // constant across the rows (or the database state) of one execution.
            return false
        case .binary(.match, _, _):
            // An access path the planner consumes; row-evaluating it is an error.
            return false
        case .function(let name, let args, _, _):
            if nonDeterministicFunctions.contains(name.uppercased()) { return false }
            return args.allSatisfy(isInvariant)
        case .binary(_, let l, let r):
            return isInvariant(l) && isInvariant(r)
        case .unary(_, let inner), .cast(let inner, _), .collate(let inner, _):
            return isInvariant(inner)
        case .isNull(let inner, _):
            return isInvariant(inner)
        case .like(let subject, let pattern, _):
            return isInvariant(subject) && isInvariant(pattern)
        case .inList(let subject, let items, _):
            return isInvariant(subject) && items.allSatisfy(isInvariant)
        case .inJSONEach(let subject, let source, _):
            return isInvariant(subject) && isInvariant(source)
        case .caseWhen(let operand, let whens, let elseExpr):
            if let operand, !isInvariant(operand) { return false }
            for when in whens where !isInvariant(when.condition) || !isInvariant(when.result) {
                return false
            }
            if let elseExpr, !isInvariant(elseExpr) { return false }
            return true
        }
    }

    /// Query-invariant subexpression hoisting (constant folding with bound
    /// parameters treated as per-execution constants). Rewrites `expr` so that
    /// every MAXIMAL subtree that `isInvariant` accepts is pre-evaluated ONCE
    /// (against `env`, which must already have the parameters bound) and replaced
    /// by a `.literal(value)`; row-dependent subtrees are left intact, with their
    /// invariant children folded.
    ///
    /// Applied once per execution before the row loop, this removes the per-row
    /// recomputation of param/literal-only work (e.g. the LIKE prefix pattern
    /// `? || '%'`, `CAST(? AS …)`, `LOWER(?)`) — the per-row evaluator then sees a
    /// `.literal` instead of rebuilding the same value for every matched row.
    ///
    /// Correctness: a whole subtree is evaluated only when `isInvariant` is true,
    /// i.e. it contains no row/aggregate/subquery reference and no
    /// non-deterministic function — so the single computed value provably equals
    /// what the per-row evaluator would have produced on every row. A subtree that
    /// is NOT invariant is never evaluated here; it is rebuilt from folded children
    /// (preserving its operator/shape exactly), so semantics are identical.
    ///
    /// Affinity / collation are preserved because we never fold a subtree that sits
    /// *directly* under a comparison or `IN` operator (the `affinityCritical`
    /// positions). There, a value's static comparison affinity (concat ⇒ TEXT,
    /// arithmetic/negate ⇒ NUMERIC, CAST ⇒ its type) and any explicit `COLLATE`
    /// drive `applyComparisonAffinity` / `resolveCollation`, and collapsing the
    /// subtree to a `.literal` (affinity `.none`, no collation) could change the
    /// comparison. So at those positions we keep the operand's top operator and
    /// fold only its (non-critical) children — the operand's affinity and collation
    /// are then byte-identical to the unfolded plan, while the param lookups /
    /// function calls inside it are still hoisted. Everywhere else (LIKE pattern,
    /// CASE arms, projection outputs, ORDER BY keys, boolean WHERE/ON, function
    /// args) affinity is irrelevant to the value, so the whole invariant subtree
    /// collapses to its constant.
    static func foldInvariant(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> SQLExpr {
        try foldInvariant(expr, env, affinityCritical: false)
    }

    private static func foldInvariant(
        _ expr: SQLExpr, _ env: SQLEvalEnv, affinityCritical: Bool
    ) throws(DBError) -> SQLExpr {
        // Maximal invariant subtree → evaluate once, substitute the constant. Skipped
        // at a comparison/IN operand position, where the operator's static affinity
        // and any COLLATE must survive (fold the children instead, below).
        if !affinityCritical, isInvariant(expr) {
            return .literal(try evaluate(expr, env))
        }
        // Otherwise rebuild this node with each child folded. Children that are
        // themselves comparison/IN operands re-set `affinityCritical`.
        switch expr {
        case .literal, .parameter, .column, .boundColumn, .aggregateResult, .scalarSubquery:
            // Leaves: literals/params already handled above (or affinity-critical and
            // left intact); row/aggregate values and a per-row subquery are never
            // rewritten here (a subquery folds its own inner expressions when it runs).
            return expr
        case .binary(let op, let l, let r) where op.isComparison:
            // The operands drive comparison affinity + collation: fold their children
            // only, keeping each operand's top operator (its affinity is preserved).
            return .binary(
                op, try foldInvariant(l, env, affinityCritical: true),
                try foldInvariant(r, env, affinityCritical: true))
        case .binary(let op, let l, let r):
            // Non-comparison (AND/OR/concat/arithmetic/json/MATCH): operands are not
            // affinity-critical. `.match` reaches here too (never invariant); its
            // operands are an FTS ref + query, so folding them is a correct no-op.
            return .binary(op, try foldInvariant(l, env), try foldInvariant(r, env))
        case .unary(let op, let inner):
            return .unary(op, try foldInvariant(inner, env))
        case .cast(let inner, let type):
            return .cast(try foldInvariant(inner, env), type)
        case .collate(let inner, let collation):
            return .collate(try foldInvariant(inner, env), collation)
        case .isNull(let inner, let negated):
            return .isNull(try foldInvariant(inner, env), negated: negated)
        case .like(let subject, let pattern, let negated):
            // The canonical win: `col LIKE ? || '%'` keeps `subject` (a column) but
            // folds the invariant `pattern` to a single `.literal(.text("term%"))`.
            // LIKE applies no affinity, so neither side is affinity-critical.
            return .like(
                try foldInvariant(subject, env),
                pattern: try foldInvariant(pattern, env), negated: negated)
        case .inList(let subject, let items, let negated):
            // `IN` compares the subject against each item under comparison affinity,
            // so every operand is affinity-critical.
            var folded: [SQLExpr] = []
            folded.reserveCapacity(items.count)
            for item in items { folded.append(try foldInvariant(item, env, affinityCritical: true)) }
            return .inList(
                try foldInvariant(subject, env, affinityCritical: true), folded, negated: negated)
        case .inJSONEach(let subject, let source, let negated):
            // The subject is compared against each json_each value (affinity-critical);
            // the source is a plain TEXT argument (not).
            return .inJSONEach(
                try foldInvariant(subject, env, affinityCritical: true),
                source: try foldInvariant(source, env), negated: negated)
        case .caseWhen(let operand, let whens, let elseExpr):
            // With an operand, each WHEN condition is compared to it (affinity-critical
            // on both sides); without one, conditions are plain booleans. Results and
            // ELSE are values (not compared), so never affinity-critical.
            let operandCritical = operand != nil
            var foldedWhens: [SQLWhen] = []
            foldedWhens.reserveCapacity(whens.count)
            for when in whens {
                foldedWhens.append(
                    SQLWhen(
                        condition: try foldInvariant(
                            when.condition, env, affinityCritical: operandCritical),
                        result: try foldInvariant(when.result, env)))
            }
            return .caseWhen(
                operand: try operand.map { e throws(DBError) in
                    try foldInvariant(e, env, affinityCritical: true)
                },
                whens: foldedWhens,
                elseExpr: try elseExpr.map { e throws(DBError) in try foldInvariant(e, env) })
        case .function(let name, let args, let star, let offset):
            // A non-deterministic function (or one with a row-dependent arg) reaches
            // here; fold only its invariant arguments, keep the call. Arguments are
            // function inputs, not comparison operands, so not affinity-critical.
            var foldedArgs: [SQLExpr] = []
            foldedArgs.reserveCapacity(args.count)
            for arg in args { foldedArgs.append(try foldInvariant(arg, env)) }
            return .function(name: name, args: foldedArgs, star: star, offset: offset)
        }
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
        case .binary(.jsonExtract, _, _), .binary(.jsonExtractText, _, _):
            return .none
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
        applyAffinities(affinity(l, env), affinity(r, env), &lv, &rv)
    }

    /// The value-conversion half of comparison affinity, with both sides' affinities
    /// already resolved — so the compiled evaluator can bake the (schema-fixed)
    /// affinities at compile time and apply only the runtime value coercion per row.
    static func applyAffinities(
        _ la: Affinity, _ ra: Affinity, _ lv: inout Value, _ rv: inout Value
    ) {
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
    /// Maps a three-way comparison result (`<0`, `0`, `>0`) to this operator's
    /// boolean outcome, or nil for non-comparison operators. Single source of
    /// truth for `isComparison`, so the predicate and the evaluation cannot drift.
    func comparisonResult(_ ordering: Int) -> Bool? {
        switch self {
        case .eq: return ordering == 0
        case .ne: return ordering != 0
        case .lt: return ordering < 0
        case .le: return ordering <= 0
        case .gt: return ordering > 0
        case .ge: return ordering >= 0
        default: return nil
        }
    }

    var isComparison: Bool { comparisonResult(0) != nil }
}
